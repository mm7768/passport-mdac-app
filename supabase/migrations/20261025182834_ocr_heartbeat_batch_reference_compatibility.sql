-- OCR batches do not belong to worker_heartbeats.current_batch_id's automation_batches FK.
create or replace function public.heartbeat_ocr_v2(p_worker_id text,p_batch_id uuid default null,p_status public.worker_status default 'ONLINE',p_hostname text default 'local',p_version text default 'ocr-v2',p_lease_seconds integer default 900)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.ocr_require_fence(p_worker_id,case when p_status='BUSY' then p_batch_id else null end);
 if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then raise exception 'Invalid lease bound'; end if;
 if p_status='BUSY' and p_batch_id is not null then update public.ocr_batches
 set locked_at=clock_timestamp(),lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds) where id=p_batch_id; end if;
 insert into public.worker_heartbeats(worker_id,hostname,version,status,current_batch_id,last_seen_at,metadata)
 values(p_worker_id,p_hostname,p_version,p_status,null,clock_timestamp(),
 jsonb_build_object('execution_mode','AZURE_OCR','claim_protocol',2,'ocr_batch_id',case when p_status='BUSY' then p_batch_id else null end))
 on conflict(worker_id) do update set hostname=excluded.hostname,version=excluded.version,status=excluded.status,
 current_batch_id=null,last_seen_at=excluded.last_seen_at,metadata=excluded.metadata;
end $$;
revoke all on function public.heartbeat_ocr_v2(text,uuid,public.worker_status,text,text,integer) from public,anon,authenticated;
grant execute on function public.heartbeat_ocr_v2(text,uuid,public.worker_status,text,text,integer) to service_role;

create or replace function public.release_unstarted_ocr_batch_v2(p_worker_id text,p_batch_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare h jsonb; b public.ocr_batches;
begin
 h:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
 if h->>'x-mdac-protocol' is distinct from '2' then raise exception 'Fenced protocol required' using errcode='42501'; end if;
 select * into b from public.ocr_batches where id=p_batch_id for update;
 if not found or b.status::text<>'PROCESSING' or b.locked_by is distinct from p_worker_id or b.claim_token is null
 or b.claim_token::text is distinct from h->>'x-mdac-batch-token'
 or b.external_started_at is not null or b.provider_operation_url is not null
 or exists(select 1 from public.ocr_results where batch_id=p_batch_id) then
 raise exception 'Only the exact unstarted OCR claim can be released' using errcode='42501'; end if;
 update public.ocr_batches set status='UPLOADED',locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,
 metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('unstarted_release_at',clock_timestamp(),'unstarted_release_reason','startup compatibility repair')
 where id=p_batch_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(null,'OCR_UNSTARTED_LEASE_RELEASED','ocr_batches',p_batch_id,
 jsonb_build_object('worker_id',p_worker_id,'provider_started',false,'attempt_count_preserved',b.attempt_count));
end $$;
revoke all on function public.release_unstarted_ocr_batch_v2(text,uuid) from public,anon,authenticated;
grant execute on function public.release_unstarted_ocr_batch_v2(text,uuid) to service_role;
notify pgrst,'reload schema';
