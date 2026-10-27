-- Additional negative/race fixtures; new synthetic schema only.
select manual_retry_acceptance_20261028.new_batch('archived_customer','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('deleted_customer','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('archived_case','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('forged_audit','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('result_writer_first','MDAC_REGISTRATION','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('retry_writer_first','MDAC_REGISTRATION','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('result_lock_contention','MDAC_REGISTRATION','UNCERTAIN');
update manual_retry_acceptance_20261028.customers set website_archived_at=clock_timestamp()
 where id in(select customer_id from manual_retry_acceptance_20261028.automation_items
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='archived_customer'));
update manual_retry_acceptance_20261028.customers set deleted_at=clock_timestamp()
 where id in(select customer_id from manual_retry_acceptance_20261028.automation_items
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='deleted_customer'));
update manual_retry_acceptance_20261028.customer_cases set website_archived_at=clock_timestamp()
 where id in(select case_id from manual_retry_acceptance_20261028.automation_items
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='archived_case'));

-- Reproduce current policy's permitted shape: an active authenticated actor may
-- write its own actor_id but arbitrary action/entity metadata. Never trust it.
insert into manual_retry_acceptance_20261028.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 select '22222222-2222-4222-8222-222222222222','MDAC_AUTO_WORKER_SUBMIT','automation_items',i.id,
 '{"status":"SUCCEEDED","submitted":true}'::jsonb from manual_retry_acceptance_20261028.automation_items i
 where i.batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='forged_audit');
insert into manual_retry_acceptance_20261028.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 select '11111111-1111-4111-8111-111111111111','MDAC_HUMAN_SUCCESS','automation_items',i.id,
 '{"status":"SUCCEEDED","submitted":true}'::jsonb from manual_retry_acceptance_20261028.automation_items i
 where i.batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='forged_audit');
begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $extension_tests$
declare t text; bid uuid; p jsonb; r jsonb;
begin
 foreach t in array array['archived_customer','deleted_customer','archived_case'] loop
  bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key=t);
  p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
  perform manual_retry_acceptance_20261028.check_true(t||'_preview_blocked',p->>'status'='BLOCKED' and p->>'blocked_reason'='ARCHIVED_CONTEXT');
  perform manual_retry_acceptance_20261028.expect_error(t||'_request_rejected',
    format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L,true)',bid,gen_random_uuid(),p->>'snapshot_token'),'P0001','ARCHIVED_CONTEXT');
 end loop;
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='forged_audit');
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 perform manual_retry_acceptance_20261028.check_true('user_forged_success_or_submit_audit_not_authoritative',
   p->>'safe_count'='1' and p->>'uncertain_count'='0' and p->>'excluded_success_count'='0');
 r:=manual_retry_acceptance_20261028.request_automation_manual_retry(bid,gen_random_uuid(),p->>'snapshot_token');
 perform manual_retry_acceptance_20261028.check_true('user_forged_audit_does_not_force_confirmation',r->>'requeued_count'='1');
 foreach t in array array['result_writer_first','retry_writer_first','result_lock_contention'] loop
  bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key=t);
  p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
  insert into manual_retry_acceptance_20261028.test_context values(t||'_preview',p);
 end loop;
end $extension_tests$;
commit;

-- The actual archived-case guard body also remains a second-line protection.
select manual_retry_acceptance_20261028.expect_error('actual_archive_guard_rejects_direct_requeue',
 $$update manual_retry_acceptance_20261028.automation_items set status='QUEUED'
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='archived_case')$$,
 'P0001','Website trash');
select jsonb_build_object('checks',count(*),'passed',count(*) filter(where passed),'failed',count(*) filter(where not passed))
 as extended_summary from manual_retry_acceptance_20261028.test_checks;
