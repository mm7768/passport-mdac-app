-- Execute ONLY in the explicitly approved nonproduction acceptance project.
-- Synthetic JWT claims with actual PostgreSQL roles, not live Auth logins.
create function manual_retry_acceptance_20261028.check_true(p_name text,p_condition boolean)
returns void language plpgsql set search_path='' as $fn$
begin
 insert into manual_retry_acceptance_20261028.test_checks(name,passed)
 values(p_name,coalesce(p_condition,false));
 if not coalesce(p_condition,false) then raise exception 'Acceptance assertion failed: %',p_name; end if;
end $fn$;
create function manual_retry_acceptance_20261028.expect_error(
 p_name text,p_sql text,p_state text,p_message text default null)
returns void language plpgsql set search_path='' as $fn$
declare v_ok boolean:=false; v_error_state text; v_error_message text;
begin
 begin execute p_sql;
 exception when others then
  get stacked diagnostics v_error_state=returned_sqlstate,v_error_message=message_text;
  v_ok:=v_error_state=p_state and (p_message is null or position(p_message in v_error_message)>0);
 end;
 insert into manual_retry_acceptance_20261028.test_checks(name,passed,details)
 values(p_name,v_ok,jsonb_build_object('actual_sqlstate',v_error_state));
 if not v_ok then raise exception 'Wrong acceptance error: %, state %, message %',p_name,v_error_state,v_error_message; end if;
end $fn$;
grant execute on function manual_retry_acceptance_20261028.check_true(text,boolean),
 manual_retry_acceptance_20261028.expect_error(text,text,text,text) to authenticated,anon,service_role;
grant select,insert on manual_retry_acceptance_20261028.test_checks to anon,service_role;

create function manual_retry_acceptance_20261028.new_batch(p_key text,p_type text,p_risk text)
returns uuid language plpgsql set search_path='' as $fn$
declare bid uuid:=gen_random_uuid(); cid uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid(); iid uuid:=gen_random_uuid();
begin
 insert into manual_retry_acceptance_20261028.customers values(cid);
 insert into manual_retry_acceptance_20261028.customer_cases values(oid,cid);
 insert into manual_retry_acceptance_20261028.automation_batches(id,task_type,created_by,status,total_count)
 values(bid,p_type,'11111111-1111-4111-8111-111111111111','NEEDS_REVIEW',1);
 insert into manual_retry_acceptance_20261028.automation_items
 (id,batch_id,customer_id,case_id,status,result_unknown,submission_started_at,
  attempt_count,error_code,error_message,claim_token,external_started_at,started_at,finished_at)
 values(iid,bid,cid,oid,case when p_risk='SAFE' then 'FAILED' else 'NEEDS_REVIEW' end,
  p_risk<>'SAFE',case when p_risk='UNCERTAIN' then clock_timestamp() else null end,
  2,'SYNTHETIC_FAILURE','SYNTHETIC OLD ERROR',gen_random_uuid(),clock_timestamp(),clock_timestamp(),clock_timestamp());
 if p_type='MDAC_REGISTRATION' then
  insert into manual_retry_acceptance_20261028.mdac_registrations(batch_item_id,customer_id,case_id,registration_status,submitted_at,raw_summary)
  values(iid,cid,oid,'NEEDS_REVIEW',case when p_risk='UNCERTAIN' then clock_timestamp() else null end,
    jsonb_build_object('synthetic',true,'submitted',p_risk='UNCERTAIN'));
 elsif p_type='REGISTRATION_CHECK' then
  insert into manual_retry_acceptance_20261028.registration_checks(batch_item_id,status,raw_summary)
  values(iid,'NEEDS_REVIEW',jsonb_build_object('synthetic',true,'old_query','QUERY_UNKNOWN'));
 elsif p_type='GMAIL_PIN' then
  insert into manual_retry_acceptance_20261028.email_pin_records(batch_item_id,status,raw_summary)
  values(iid,'NOT_FOUND',jsonb_build_object('synthetic',true,'old_query','PIN_LOOKUP_FAILED'));
 else
  insert into manual_retry_acceptance_20261028.visit_pass_checks(batch_item_id,status,raw_summary)
  values(iid,'NEEDS_REVIEW',jsonb_build_object('synthetic',true,'old_query','QUERY_UNKNOWN'));
 end if;
 insert into manual_retry_acceptance_20261028.test_context values(p_key,to_jsonb(bid));
 return bid;
end $fn$;
revoke all on function manual_retry_acceptance_20261028.new_batch(text,text,text) from public,anon,authenticated,service_role;

select manual_retry_acceptance_20261028.new_batch('uncertain','MDAC_REGISTRATION','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('stale','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('item_limit','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('batch_limit','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('lease','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('overlap','MDAC_REGISTRATION','SAFE');
select manual_retry_acceptance_20261028.new_batch('audit_success','MDAC_REGISTRATION','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('REGISTRATION_CHECK','REGISTRATION_CHECK','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('GMAIL_PIN','GMAIL_PIN','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('VISIT_PASS_CHECK','VISIT_PASS_CHECK','UNCERTAIN');
select manual_retry_acceptance_20261028.new_batch('no_automatic_retry','REGISTRATION_CHECK','SAFE');
select manual_retry_acceptance_20261028.new_batch('concurrent','GMAIL_PIN','SAFE');
update manual_retry_acceptance_20261028.automation_items set attempt_count=5
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='item_limit');
update manual_retry_acceptance_20261028.automation_batches set attempt_count=5
 where id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='batch_limit');
update manual_retry_acceptance_20261028.automation_batches set lease_expires_at=clock_timestamp()+interval '10 minutes'
 where id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='lease');
insert into manual_retry_acceptance_20261028.audit_logs(action,entity_type,entity_id,metadata)
 select 'MDAC_AUTO_WORKER_SUBMIT','automation_items',i.id,'{"status":"SUCCEEDED"}'
 from manual_retry_acceptance_20261028.automation_items i
 where i.batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='audit_success');
-- An unfinished sibling for the same customer, in another batch.
insert into manual_retry_acceptance_20261028.automation_batches(id,task_type,created_by,status)
 values('a2000000-0000-4000-8000-000000000001','REGISTRATION_CHECK','11111111-1111-4111-8111-111111111111','NEEDS_REVIEW');
insert into manual_retry_acceptance_20261028.automation_items(batch_id,customer_id,case_id,status,result_unknown)
 select 'a2000000-0000-4000-8000-000000000001',customer_id,case_id,'NEEDS_REVIEW',true
 from manual_retry_acceptance_20261028.automation_items
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='overlap');

-- Auth/account negative cases. An unrelated FULL OWNER is not a creator override.
begin;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select manual_retry_acceptance_20261028.expect_error('anonymous_denied',
 $$select manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001')$$,'42501');
commit;
begin;
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role","sub":"11111111-1111-4111-8111-111111111111"}',true);
select manual_retry_acceptance_20261028.expect_error('service_role_no_bypass',
 $$select manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001')$$,'42501');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"22222222-2222-4222-8222-222222222222"}',true);
select manual_retry_acceptance_20261028.expect_error('wrong_creator_even_owner_denied',
 $$select manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001')$$,'42501','BATCH_NOT_OWNED');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"33333333-3333-4333-8333-333333333333"}',true);
select manual_retry_acceptance_20261028.expect_error('inactive_denied',
 $$select manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001')$$,'42501','ACTIVE_FULL');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"44444444-4444-4444-8444-444444444444"}',true);
select manual_retry_acceptance_20261028.expect_error('review_only_denied',
 $$select manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001')$$,'42501','ACTIVE_FULL');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"55555555-5555-4555-8555-555555555555"}',true);
select manual_retry_acceptance_20261028.expect_error('expired_denied',
 $$select manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001')$$,'42501','ACTIVE_FULL');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $tests$
declare p jsonb; r jsonb; bid uuid; token text; replay jsonb; t text;
begin
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry('a1000000-0000-4000-8000-000000000001');
 perform manual_retry_acceptance_20261028.check_true('preview_13_success_1_safe_1_uncertain',
  p->>'status'='READY' and p->>'safe_count'='1' and p->>'uncertain_count'='1' and p->>'excluded_success_count'='13');
 insert into manual_retry_acceptance_20261028.test_context values('original_preview',p);
 perform manual_retry_acceptance_20261028.expect_error('direct_protected_patch_denied',
  $$update manual_retry_acceptance_20261028.automation_items set status='QUEUED' where id='d1000000-0000-4000-8000-000000000014'$$,'42501','fenced RPC');
 r:=manual_retry_acceptance_20261028.request_automation_manual_retry(
  'a1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001',p->>'snapshot_token');
 perform manual_retry_acceptance_20261028.check_true('safe_only_default_queues_one',r->>'requeued_count'='1' and r->>'replayed'='false');
 replay:=manual_retry_acceptance_20261028.request_automation_manual_retry(
  'a1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001',p->>'snapshot_token');
 perform manual_retry_acceptance_20261028.check_true('same_request_replay_ack',replay->>'replayed'='true' and replay->>'requeued_count'='1');
 perform manual_retry_acceptance_20261028.expect_error('replay_cannot_escalate_uncertain',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L,true)',
  'a1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001',p->>'snapshot_token'),
  '22023','REQUEST_ID_REUSED');
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='uncertain');
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 perform manual_retry_acceptance_20261028.expect_error('uncertain_requires_explicit_true',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',
  bid,'e1000000-0000-4000-8000-000000000002',p->>'snapshot_token'),'P0001','EXPLICIT_CONFIRMATION');
 r:=manual_retry_acceptance_20261028.request_automation_manual_retry(
  bid,'e1000000-0000-4000-8000-000000000002',p->>'snapshot_token',true);
 perform manual_retry_acceptance_20261028.check_true('uncertain_true_queues_original_item',r->>'requeued_count'='1' and r->>'uncertain_count'='1');
 perform manual_retry_acceptance_20261028.expect_error('reused_request_other_batch_denied',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L,true)',
  'a1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000002',p->>'snapshot_token'),
  '22023','REQUEST_ID_REUSED');
 foreach t in array array['GMAIL_PIN','REGISTRATION_CHECK','VISIT_PASS_CHECK'] loop
  bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key=t);
  p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
  perform manual_retry_acceptance_20261028.check_true(t||'_query_unknown_is_manual_safe',
   p->>'task_type'=t and p->>'safe_count'='1' and p->>'uncertain_count'='0');
  r:=manual_retry_acceptance_20261028.request_automation_manual_retry(bid,gen_random_uuid(),p->>'snapshot_token');
  perform manual_retry_acceptance_20261028.check_true(t||'_manual_request_queued',r->>'requeued_count'='1');
 end loop;
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='lease');
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 perform manual_retry_acceptance_20261028.check_true('leased_preview_blocked',p->>'status'='BLOCKED' and p->>'blocked_reason'='ACTIVE_WORK');
 perform manual_retry_acceptance_20261028.expect_error('leased_request_rejected',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',bid,gen_random_uuid(),p->>'snapshot_token'),'P0001','ACTIVE_WORK');
 foreach t in array array['item_limit','batch_limit'] loop
  bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key=t);
  p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
  perform manual_retry_acceptance_20261028.check_true(t||'_preview_blocked',p->>'status'='BLOCKED' and p->>'blocked_reason'='ATTEMPT_LIMIT');
  perform manual_retry_acceptance_20261028.expect_error(t||'_request_rejected',
   format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',bid,gen_random_uuid(),p->>'snapshot_token'),
   'P0001',case when t='batch_limit' then 'ATTEMPT_LIMIT' else 'NO_ELIGIBLE_ITEMS' end);
 end loop;
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='overlap');
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 perform manual_retry_acceptance_20261028.expect_error('customer_overlap_rejected',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',bid,gen_random_uuid(),p->>'snapshot_token'),'P0001','CUSTOMER_OVERLAP');
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='audit_success');
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 perform manual_retry_acceptance_20261028.check_true('known_audit_success_excluded',p->>'excluded_success_count'='1' and p->>'uncertain_count'='0');
 perform manual_retry_acceptance_20261028.expect_error('force_cannot_repeat_audit_success',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L,true)',bid,gen_random_uuid(),p->>'snapshot_token'),'P0001','NO_ELIGIBLE_ITEMS');
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='stale');
 p:=manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 insert into manual_retry_acceptance_20261028.test_context values('stale_preview',p);
 perform manual_retry_acceptance_20261028.expect_error('invalid_snapshot_rejected',
  format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',bid,gen_random_uuid(),'invalid'),'22023','INVALID_REQUEST');
 bid:=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='no_automatic_retry');
 perform manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
 perform manual_retry_acceptance_20261028.preview_automation_manual_retry(bid);
end $tests$;
commit;

-- Server-only verification of immutable history, results and success records.
select manual_retry_acceptance_20261028.check_true('success_13_items_byte_unchanged',
 (select jsonb_agg(to_jsonb(i) order by id) from manual_retry_acceptance_20261028.automation_items i where id in
  (select (x->>'id')::uuid from jsonb_array_elements((select value from manual_retry_acceptance_20261028.test_context where key='success_items')) x))
 =(select value from manual_retry_acceptance_20261028.test_context where key='success_items'));
select manual_retry_acceptance_20261028.check_true('all_original_mdac_results_byte_unchanged',
 (select jsonb_agg(to_jsonb(r) order by id) from manual_retry_acceptance_20261028.mdac_registrations r
   where batch_item_id in(select (x->>'id')::uuid from jsonb_array_elements((select value from manual_retry_acceptance_20261028.test_context where key='all_original_items'))x))
 =(select value from manual_retry_acceptance_20261028.test_context where key='all_result_rows'));
select manual_retry_acceptance_20261028.check_true('safe_only_keeps_uncertain_current_item_byte_unchanged',
 (select to_jsonb(i)=x from manual_retry_acceptance_20261028.automation_items i,
 jsonb_array_elements((select value from manual_retry_acceptance_20261028.test_context where key='all_original_items'))x
 where i.id='d1000000-0000-4000-8000-000000000015' and x->>'id'=i.id::text));
select manual_retry_acceptance_20261028.check_true('safe_request_has_one_history_no_duplicate',
 (select count(*)=1 from manual_retry_acceptance_20261028.automation_manual_retry_history where request_id='e1000000-0000-4000-8000-000000000001'));
select manual_retry_acceptance_20261028.check_true('history_saved_all_old_submission_and_error_state',
 (select before_item->>'result_unknown'='true' and before_item->>'submission_started_at' is not null
    and before_item->>'attempt_count'='2' and before_item->>'error_message'='SYNTHETIC OLD ERROR'
    and uncertain_reexecution_confirmed and jsonb_array_length(before_results->'mdac')=1
  from manual_retry_acceptance_20261028.automation_manual_retry_history where request_id='e1000000-0000-4000-8000-000000000002'));
select manual_retry_acceptance_20261028.check_true('identity_case_customer_attempt_not_reset',
 not exists(select 1 from manual_retry_acceptance_20261028.automation_manual_retry_history h
 join manual_retry_acceptance_20261028.automation_items i on i.id=h.item_id
 where i.case_id is distinct from h.case_id or i.customer_id<>h.customer_id or i.batch_id<>h.batch_id or i.attempt_count<>h.attempt_count));
select manual_retry_acceptance_20261028.check_true('three_query_result_histories_preserved',
 (select count(*)=3 from manual_retry_acceptance_20261028.automation_manual_retry_history h
 join manual_retry_acceptance_20261028.automation_batches b on b.id=h.batch_id
 where b.task_type in ('GMAIL_PIN','REGISTRATION_CHECK','VISIT_PASS_CHECK')
   and h.before_item->>'result_unknown'='true' and h.risk_class='SAFE'
   and not h.uncertain_reexecution_confirmed));
select manual_retry_acceptance_20261028.check_true('preview_does_not_auto_enqueue',
 (select i.status='FAILED' from manual_retry_acceptance_20261028.automation_items i
 where i.batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='no_automatic_retry')));
select manual_retry_acceptance_20261028.check_true('history_no_client_or_service_write_grants',
 not has_table_privilege('authenticated','manual_retry_acceptance_20261028.automation_manual_retry_history','INSERT,UPDATE,DELETE')
 and not has_table_privilege('service_role','manual_retry_acceptance_20261028.automation_manual_retry_history','INSERT,UPDATE,DELETE'));
select manual_retry_acceptance_20261028.check_true('current_counts_do_not_count_attempt_history',
 (select total_count=15 and success_count=13 and failed_count=0 from manual_retry_acceptance_20261028.automation_batches where id='a1000000-0000-4000-8000-000000000001'));

-- Simulate a later Worker claim without invoking any provider. Late replay must
-- not reset a new claim or its attempt count/token. Full provider lifecycle is
-- explicitly outside this focused synthetic fixture.
update manual_retry_acceptance_20261028.automation_items set status='RUNNING',
 attempt_count=attempt_count+1,claim_token=gen_random_uuid(),locked_by='SYNTHETIC WORKER',
 lease_expires_at=clock_timestamp()+interval '10 minutes'
 where id='d1000000-0000-4000-8000-000000000014';
update manual_retry_acceptance_20261028.automation_items set error_message='SYNTHETIC CHANGED AFTER PREVIEW'
 where batch_id=(select (value#>>'{}')::uuid from manual_retry_acceptance_20261028.test_context where key='stale');
begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
select manual_retry_acceptance_20261028.expect_error('late_replay_after_claim_rejected',
 format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',
 'a1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001',
 (select value->>'snapshot_token' from manual_retry_acceptance_20261028.test_context where key='original_preview')),
 '40001','ALREADY_ADVANCED');
select manual_retry_acceptance_20261028.expect_error('stale_preview_rejected',
 format('select manual_retry_acceptance_20261028.request_automation_manual_retry(%L,%L,%L)',
 (select value#>>'{}' from manual_retry_acceptance_20261028.test_context where key='stale'),gen_random_uuid(),
 (select value->>'snapshot_token' from manual_retry_acceptance_20261028.test_context where key='stale_preview')),
 '40001','SNAPSHOT_CHANGED');
commit;
select manual_retry_acceptance_20261028.check_true('late_replay_did_not_change_new_attempt',
 (select status='RUNNING' and attempt_count=2 and locked_by='SYNTHETIC WORKER'
 from manual_retry_acceptance_20261028.automation_items where id='d1000000-0000-4000-8000-000000000014'));
select jsonb_build_object('checks',(select count(*) from manual_retry_acceptance_20261028.test_checks),
 'passed',(select count(*) from manual_retry_acceptance_20261028.test_checks where passed),
 'failed',(select count(*) from manual_retry_acceptance_20261028.test_checks where not passed)) as acceptance_summary;
