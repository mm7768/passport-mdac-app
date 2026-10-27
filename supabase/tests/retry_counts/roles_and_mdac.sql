begin;
set local role authenticated;
do $$ declare uid text; begin
 foreach uid in array array['22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444'] loop
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',uid)::text,true);
  begin
   perform mdac_retry_app_20261027.requeue_automation_batch('a1000000-0000-4000-8000-000000000001');
   raise exception 'Unauthorized retry succeeded';
  exception when insufficient_privilege then
   insert into mdac_retry_app_20261027.test_checks values('unauthorized_retry_'||left(uid,1),true);
  end;
 end loop;
 perform set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
 begin
  perform mdac_retry_app_20261027.claim_mdac_batch('forbidden-client');
  raise exception 'Ordinary client could claim';
 exception when insufficient_privilege then
  insert into mdac_retry_app_20261027.test_checks values('client_still_cannot_claim_worker_tasks',true);
 end;
end $$;
commit;

begin;
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select set_config('request.headers','{"x-mdac-protocol":"2"}',true);
do $$ declare b mdac_retry_app_20261027.automation_batches; i mdac_retry_app_20261027.automation_items; t uuid; begin
 select * into b from mdac_retry_app_20261027.claim_mdac_batch('ISOLATED-mdac-retry',900,5);
 if b.id is distinct from 'a1000000-0000-4000-8000-000000000001'::uuid then raise exception 'Unexpected batch claimed'; end if;
 perform set_config('request.headers',jsonb_build_object('x-mdac-protocol','2','x-mdac-batch-token',b.claim_token)::text,true);
 select * into i from mdac_retry_app_20261027.claim_mdac_item(b.id,'ISOLATED-mdac-retry',900,5);
 if i.id is distinct from (select value from mdac_retry_app_20261027.test_context where key='safe_item') or i.attempt_count<>3 then raise exception 'Wrong item or attempt'; end if;
 t:=i.claim_token;
 perform set_config('request.headers',jsonb_build_object('x-mdac-protocol','2','x-mdac-batch-token',b.claim_token,'x-mdac-item-token',t)::text,true);
 perform mdac_retry_app_20261027.heartbeat_mdac('ISOLATED-mdac-retry',b.id,i.id,900,'BUSY','ISOLATED','retry-test');
 if not mdac_retry_app_20261027.mdac_begin_external_v2('ISOLATED-mdac-retry',i.id) then raise exception 'External permit unavailable'; end if;
 perform mdac_retry_app_20261027.mdac_before_submit_v2('ISOLATED-mdac-retry',i.id);
 -- Simulated result: no HTTP request or government submission happens in this SQL test.
 perform mdac_retry_app_20261027.finish_mdac_registration_worker(p_item_id=>i.id,p_worker_id=>'ISOLATED-mdac-retry',p_status=>'SUCCEEDED',p_registration_no=>'ISOLATED-REG-001',p_raw_summary=>'{"submitted":true,"result_confirmed":true,"isolated_provider":true}');
 if not exists(select 1 from mdac_retry_app_20261027.automation_batches where id=b.id and total_count=20 and success_count=20 and failed_count=0 and status::text='SUCCEEDED') then raise exception 'Completion counters incorrect'; end if;
 if (select count(*) from mdac_retry_app_20261027.mdac_registrations where batch_item_id=i.id)<>1 then raise exception 'Result count mismatch'; end if;
 if not exists(select 1 from mdac_retry_app_20261027.mdac_registrations where batch_item_id=i.id and case_id=i.case_id) then raise exception 'Case binding lost'; end if;
 begin
  perform mdac_retry_app_20261027.finish_mdac_registration_worker(p_item_id=>i.id,p_worker_id=>'ISOLATED-mdac-retry',p_status=>'SUCCEEDED');
  raise exception 'Late completion accepted';
 exception when insufficient_privilege then null;
 end;
 insert into mdac_retry_app_20261027.test_checks values
 ('mdac_retry_claim_heartbeat_finish_and_case_binding',true),('mdac_attempt_2_to_3_without_new_item',true),
 ('mdac_result_written_once_late_callback_rejected',true),('completed_counts_20_of_20',true);
end $$;
commit;
