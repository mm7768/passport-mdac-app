-- Administrative RPC: no application role receives execution permission.
create function private.retarget_stopped_visit_batch_v1(p_batch_id uuid,p_request_id uuid,p_email text,p_entry_date date)
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare b public.automation_batches; i public.automation_items; actor uuid:=auth.uid();
 req private.automation_manual_retry_requests; state jsonb; result jsonb; n integer:=0;
 target_email text:=lower(btrim(p_email));
begin
 if current_user not in ('postgres','supabase_admin') then raise exception 'Maintenance role required' using errcode='42501'; end if;
 perform private.automation_manual_retry_assert_actor(actor);
 if p_request_id is null or p_entry_date is null or target_email is null or length(target_email)>254
 or target_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+[.][a-z]{2,}$' then raise exception 'Invalid request, email or entry date'; end if;
 select * into b from public.automation_batches where id=p_batch_id for update;
 if not found or b.task_type::text<>'VISIT_PASS_CHECK' or b.created_by is distinct from actor then raise exception 'Owned Visit Pass batch required' using errcode='42501'; end if;
 select * into req from private.automation_manual_retry_requests where actor_id=actor and request_id=p_request_id for update;
 if found then
  if req.batch_id<>p_batch_id or req.response->>'email' is distinct from target_email or req.response->>'entry_date' is distinct from p_entry_date::text then raise exception 'Request ID reused with different arguments'; end if;
  return req.response||jsonb_build_object('replayed',true);
 end if;
 perform 1 from public.automation_items where batch_id=p_batch_id order by id for update;
 if b.lease_expires_at>clock_timestamp() or b.status::text in ('RUNNING','CLAIMED')
 or exists(select 1 from public.automation_items where batch_id=p_batch_id and (status::text in ('RUNNING','CLAIMED') or lease_expires_at>clock_timestamp())) then raise exception 'Drain the Worker before changing query settings'; end if;
 if b.attempt_count>=5 or exists(select 1 from public.automation_items where batch_id=p_batch_id and status::text<>'SUCCEEDED' and attempt_count>=5) then raise exception 'Attempt limit reached'; end if;
 if exists(select 1 from public.automation_items x join public.customers c on c.id=x.customer_id left join public.customer_cases cc on cc.id=x.case_id where x.batch_id=p_batch_id and (c.deleted_at is not null or c.website_archived_at is not null or cc.website_archived_at is not null)) then raise exception 'Archived or deleted context'; end if;
 if exists(select 1 from public.automation_items x join public.automation_items other_i on other_i.customer_id=x.customer_id and other_i.batch_id<>p_batch_id where x.batch_id=p_batch_id and other_i.status::text in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')) then raise exception 'Another task is active for a selected customer'; end if;
 if not exists(select 1 from public.automation_items where batch_id=p_batch_id and status::text in ('QUEUED','FAILED','NEEDS_REVIEW')) then raise exception 'No unfinished query items'; end if;
 state:=private.automation_manual_retry_state(p_batch_id);
 insert into private.automation_manual_retry_requests(actor_id,request_id,batch_id,snapshot_token,include_uncertain)
 values(actor,p_request_id,p_batch_id,state->>'snapshot_token',false);
 for i in select * from public.automation_items where batch_id=p_batch_id and status::text in ('QUEUED','FAILED','NEEDS_REVIEW') order by id loop
  insert into private.automation_manual_retry_history(actor_id,request_id,batch_id,item_id,customer_id,case_id,attempt_count,risk_class,uncertain_reexecution_confirmed,before_item,before_batch_state,before_results)
  values(actor,p_request_id,p_batch_id,i.id,i.customer_id,i.case_id,i.attempt_count,'SAFE',false,to_jsonb(i),to_jsonb(b),jsonb_build_object('visit_pass_check',coalesce((select jsonb_agg(to_jsonb(v) order by v.id) from public.visit_pass_checks v where v.batch_item_id=i.id),'[]'::jsonb)));
  update public.automation_items set status='QUEUED',locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,external_started_at=null,started_at=null,finished_at=null,error_code=null,error_message=null,result_unknown=false,submission_started_at=null where id=i.id;
  n:=n+1;
 end loop;
 update public.automation_batches set visit_pass_settings_snapshot=jsonb_set(visit_pass_settings_snapshot,'{email}',to_jsonb(target_email)),entry_date=p_entry_date,locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=p_batch_id;
 perform private.sync_batch_status_and_counts(p_batch_id);
 result:=jsonb_build_object('status','QUEUED','replayed',false,'task_type','VISIT_PASS_CHECK','requeued_count',n,'email',target_email,'entry_date',p_entry_date,'request_id',p_request_id);
 update private.automation_manual_retry_requests set response=result,post_snapshot_token=private.automation_manual_retry_state(p_batch_id)->>'snapshot_token' where actor_id=actor and request_id=p_request_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'VISIT_PASS_BATCH_RETARGET','automation_batches',p_batch_id,jsonb_build_object('request_id',p_request_id,'requeued_count',n,'entry_date',p_entry_date,'batch_settings_only',true,'history_preserved',true));
 return result;
end $fn$;
revoke all on function private.retarget_stopped_visit_batch_v1(uuid,uuid,text,date) from public,anon,authenticated,service_role;