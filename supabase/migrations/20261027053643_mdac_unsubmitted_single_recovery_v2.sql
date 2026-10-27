-- Administrative recovery of ONE proven pre-submit slider failure.
-- Submitted/uncertain attempts remain blocked. Ordinary clients have no access.
create or replace function public.requeue_unsubmitted_mdac_item_v2(
 p_item_id uuid, p_expected_batch_id uuid, p_expected_attempt integer,
 p_expected_updated_at timestamptz, p_expected_claim_token uuid,
 p_expected_worker_version text, p_review_reference text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.automation_items; b public.automation_batches;
 r public.mdac_registrations; wid text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then
  raise exception 'Service recovery role required' using errcode='42501'; end if;
 if nullif(trim(p_review_reference),'') is null or nullif(trim(p_expected_worker_version),'') is null then
  raise exception 'Reviewed evidence and build are required' using errcode='42501'; end if;
 select * into b from public.automation_batches where id=p_expected_batch_id for update;
 if not found or b.task_type::text<>'MDAC_REGISTRATION' or b.status::text not in ('NEEDS_REVIEW','FAILED') or b.attempt_count>=5
 or b.locked_by is not null or b.lease_expires_at>clock_timestamp()
 or (select count(*) from public.automation_items where batch_id=b.id)<>1 then
  raise exception 'Only an inactive single-item MDAC batch is recoverable' using errcode='42501'; end if;
 select * into i from public.automation_items where id=p_item_id for update;
 if not found or i.batch_id is distinct from b.id or i.status::text<>'NEEDS_REVIEW'
 or i.error_code is distinct from 'SLIDER_SOLVER_FAILED'
 or i.attempt_count is distinct from p_expected_attempt or i.attempt_count>=5
 or i.updated_at is distinct from p_expected_updated_at
 or i.claim_token is null or i.claim_token is distinct from p_expected_claim_token
 or i.locked_by is not null or i.lease_expires_at>clock_timestamp()
 or i.started_at is null or i.external_started_at is null
 or i.submission_started_at is not null then
  raise exception 'Exact completed pre-submit claim evidence required' using errcode='42501'; end if;
 select * into r from public.mdac_registrations where batch_item_id=i.id for update;
 if not found or r.registration_status::text<>'NEEDS_REVIEW'
 or r.submitted_at is not null or r.result_confirmed_at is not null
 or nullif(trim(r.registration_no),'') is not null
 or r.raw_summary->'submitted' is distinct from 'false'::jsonb
 or r.raw_summary->'result_confirmed' is distinct from 'false'::jsonb
 or r.raw_summary->'slider_solved' is distinct from 'false'::jsonb
 or r.raw_summary->'manual_review_required' is distinct from 'true'::jsonb
 or r.raw_summary->>'execution_mode' is distinct from 'AUTO_SUBMIT'
 or r.raw_summary->'human_in_loop'='true'::jsonb then
  raise exception 'Provider submission cannot be ruled out' using errcode='42501'; end if;
 wid:=r.raw_summary->>'worker_id';
 if not exists(select 1 from public.worker_heartbeats h where h.worker_id=wid
 and h.version=p_expected_worker_version and h.status::text in ('ONLINE','BUSY')
 and h.last_seen_at>clock_timestamp()-interval '3 minutes')
 or not exists(select 1 from public.audit_logs a where a.entity_id=i.id
 and a.action='MDAC_AUTO_WORKER_SUBMIT' and a.created_at>=i.started_at
 and a.metadata->>'worker_id'=wid and a.metadata->>'status'='NEEDS_REVIEW') then
  raise exception 'Verified fenced Worker completion evidence required' using errcode='42501'; end if;
 if exists(select 1 from public.audit_logs a where a.entity_id=i.id and
 (a.action in ('MDAC_HUMAN_SUBMIT_REQUESTED','MDAC_HUMAN_RESULT_UNKNOWN','MDAC_HUMAN_SUCCESS')
 or a.metadata->>'status'='SUCCEEDED' or a.metadata->'submitted'='true'::jsonb))
 or exists(select 1 from public.mdac_registrations other_result where other_result.customer_id=i.customer_id
 and other_result.batch_item_id<>i.id and other_result.entry_date=b.entry_date
 and other_result.exit_date=b.exit_date and (other_result.registration_status::text in ('SUCCEEDED','SUBMITTED','RESULT_UNKNOWN')
 or other_result.submitted_at is not null))
 or exists(select 1 from public.automation_items other_item where other_item.customer_id=i.customer_id
 and other_item.id<>i.id and other_item.status::text in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')) then
  raise exception 'Other submission or active work prevents replay' using errcode='42501'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(null,'MDAC_PROVEN_PRE_SUBMIT_RETRY','automation_items',i.id,
 jsonb_build_object('batch_id',b.id,'original_attempt',i.attempt_count,
 'original_case_id',i.case_id,'original_status',i.status,'original_result_unknown',i.result_unknown,
 'original_error_code',i.error_code,'original_started_at',i.started_at,
 'original_updated_at',i.updated_at,'worker_id',wid,'worker_version',p_expected_worker_version,
 'submission_started',false,'submitted_reported',false,'review_reference',p_review_reference));
 update public.automation_items set status='QUEUED',result_unknown=false,
 locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,
 external_started_at=null,started_at=null,finished_at=null,error_code=null,error_message=null
 where id=i.id;
 update public.automation_batches set locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=b.id;
 perform private.sync_batch_status_and_counts(b.id);
 return jsonb_build_object('item_id',i.id,'batch_id',b.id,'status','QUEUED',
 'attempt_count_preserved',i.attempt_count,'successful_items_requeued',0);
end $$;
revoke all on function public.requeue_unsubmitted_mdac_item_v2(uuid,uuid,integer,timestamptz,uuid,text,text)
 from public,anon,authenticated;
grant execute on function public.requeue_unsubmitted_mdac_item_v2(uuid,uuid,integer,timestamptz,uuid,text,text)
 to service_role;
notify pgrst,'reload schema';
