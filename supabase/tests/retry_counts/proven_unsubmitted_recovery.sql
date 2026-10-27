-- New private test schemas only. No government/provider requests.
begin;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare n integer; cid uuid; bid uuid; iid uuid; tok uuid; begin
 insert into mdac_retry_app_20261027.worker_heartbeats(worker_id,hostname,version,status,last_seen_at)
 values('ISOLATED-recovery-worker','ISOLATED','recovery-fixture-v2','ONLINE',clock_timestamp());
 for n in 1..3 loop
  insert into mdac_retry_app_20261027.customers(full_name,date_of_birth,place_of_birth,passport_number,nationality,gender,passport_expiry_date,created_by)
  values('ISOLATED RECOVERY '||n,'1990-01-01','CHINA','RECOV000'||n,'CHN','男','2035-01-01','11111111-1111-4111-8111-111111111111') returning id into cid;
  insert into mdac_retry_app_20261027.automation_batches(task_type,created_by,entry_date,exit_date,attempt_count)
  values('MDAC_REGISTRATION','11111111-1111-4111-8111-111111111111','2030-01-01','2030-01-02',0) returning id into bid;
  tok:=gen_random_uuid();
  insert into mdac_retry_app_20261027.automation_items(batch_id,customer_id,status,attempt_count,result_unknown,error_code,started_at,external_started_at,submission_started_at,claim_token)
  values(bid,cid,'NEEDS_REVIEW',1,true,'SLIDER_SOLVER_FAILED',clock_timestamp()-interval '1 minute',clock_timestamp()-interval '50 seconds',case when n=2 then clock_timestamp() else null end,tok) returning id into iid;
  insert into mdac_retry_app_20261027.mdac_registrations(customer_id,batch_item_id,entry_date,exit_date,registration_status,raw_summary)
  values(cid,iid,'2030-01-01','2030-01-02',case when n=3 then 'SUCCEEDED' else 'NEEDS_REVIEW' end::mdac_retry_app_20261027.registration_status,
   jsonb_build_object('worker_id','ISOLATED-recovery-worker','execution_mode','AUTO_SUBMIT','submitted',false,'result_confirmed',false,'slider_solved',false,'manual_review_required',true));
  insert into mdac_retry_app_20261027.audit_logs(action,entity_type,entity_id,metadata)
  values('MDAC_AUTO_WORKER_SUBMIT','automation_items',iid,'{"worker_id":"ISOLATED-recovery-worker","status":"NEEDS_REVIEW"}');
  insert into mdac_retry_app_20261027.test_context values('pre_submit_recovery_'||n,iid);
 end loop;
end $$;
commit;

begin;
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare i mdac_retry_app_20261027.automation_items; j integer; result jsonb; begin
 for j in 2..3 loop
  select * into i from mdac_retry_app_20261027.automation_items where id=(select value from mdac_retry_app_20261027.test_context where key='pre_submit_recovery_'||j);
  begin
   perform mdac_retry_app_20261027.requeue_unsubmitted_mdac_item_v2(i.id,i.batch_id,i.attempt_count,i.updated_at,i.claim_token,'recovery-fixture-v2','isolated-negative-test');
   raise exception 'Submitted or successful candidate was replayed';
  exception when insufficient_privilege then null; end;
 end loop;
 select * into i from mdac_retry_app_20261027.automation_items where id=(select value from mdac_retry_app_20261027.test_context where key='pre_submit_recovery_1');
 begin
  perform mdac_retry_app_20261027.requeue_unsubmitted_mdac_item_v2(i.id,i.batch_id,i.attempt_count,i.updated_at,gen_random_uuid(),'recovery-fixture-v2','wrong-token');
  raise exception 'Wrong recovery token accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform mdac_retry_app_20261027.requeue_unsubmitted_mdac_item_v2(i.id,i.batch_id,i.attempt_count,i.updated_at,i.claim_token,'wrong-build','wrong-build');
  raise exception 'Wrong worker build accepted';
 exception when insufficient_privilege then null; end;
 result:=mdac_retry_app_20261027.requeue_unsubmitted_mdac_item_v2(i.id,i.batch_id,i.attempt_count,i.updated_at,i.claim_token,'recovery-fixture-v2','isolated-proof-reviewed');
 if result->>'status'<>'QUEUED' or not exists(select 1 from mdac_retry_app_20261027.automation_items x where x.id=i.id and x.case_id is not distinct from i.case_id and x.customer_id=i.customer_id and x.attempt_count=1 and x.status::text='QUEUED' and not x.result_unknown and x.claim_token is null) then raise exception 'Recovery changed identity/history'; end if;
 begin
  perform mdac_retry_app_20261027.requeue_unsubmitted_mdac_item_v2(i.id,i.batch_id,i.attempt_count,i.updated_at,i.claim_token,'recovery-fixture-v2','repeat-recovery');
  raise exception 'Recovery repeated';
 exception when insufficient_privilege then null; end;
 insert into mdac_retry_app_20261027.test_checks values
 ('pre_submit_recovery_rejects_actual_submit_and_success',true),
 ('pre_submit_recovery_rejects_wrong_token_and_build',true),
 ('pre_submit_recovery_preserves_identity_attempt_and_case_null',true),
 ('pre_submit_recovery_rejects_repeat',true);
end $$;
commit;
