-- Synthetic jobs only; public production tables and providers are never touched.
begin;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare kind text; bid uuid; cid uuid; caseid uuid; ordinal integer:=0; begin
 foreach kind in array array['REGISTRATION_CHECK','VISIT_PASS_CHECK','GMAIL_PIN'] loop
  ordinal:=ordinal+1;
  select customer_id,case_id into cid,caseid from mdac_retry_app_20261027.test_item_before
  where status::text='SUCCEEDED' order by id offset (ordinal-1) limit 1;
  insert into mdac_retry_app_20261027.automation_batches(task_type,created_by,status,attempt_count)
  values(kind::mdac_retry_app_20261027.automation_task_type,'11111111-1111-4111-8111-111111111111','FAILED',1) returning id into bid;
  insert into mdac_retry_app_20261027.automation_items(batch_id,customer_id,case_id,status,attempt_count,result_unknown)
  values(bid,cid,caseid,'FAILED',2,false);
  insert into mdac_retry_app_20261027.test_context values('full_constraints_'||kind,bid);
 end loop;
end $$;
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $$ declare c record; begin
 for c in select * from mdac_retry_app_20261027.test_context where key in ('full_constraints_REGISTRATION_CHECK','full_constraints_VISIT_PASS_CHECK','full_constraints_GMAIL_PIN') loop
  perform mdac_retry_app_20261027.requeue_automation_batch(c.value);
 end loop;
end $$;
commit;

begin;
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare kind text; wid text; b mdac_retry_app_20261027.automation_batches; i mdac_retry_app_20261027.automation_items; n integer; begin
 foreach kind in array array['REGISTRATION_CHECK','VISIT_PASS_CHECK','GMAIL_PIN'] loop
  wid:='ISOLATED-final-'||kind;
  perform set_config('request.headers','{"x-mdac-protocol":"2"}',true);
  if kind='REGISTRATION_CHECK' then select * into b from mdac_retry_app_20261027.claim_registration_check_batch(wid);
  elsif kind='VISIT_PASS_CHECK' then select * into b from mdac_retry_app_20261027.claim_visit_pass_check_batch(wid);
  else select * into b from mdac_retry_app_20261027.claim_gmail_pin_batch(wid); end if;
  if b.id is distinct from (select value from mdac_retry_app_20261027.test_context where key='full_constraints_'||kind) then raise exception 'Wrong % batch',kind; end if;
  perform set_config('request.headers',jsonb_build_object('x-mdac-protocol','2','x-mdac-batch-token',b.claim_token)::text,true);
  if kind='REGISTRATION_CHECK' then select * into i from mdac_retry_app_20261027.claim_registration_check_item(b.id,wid);
  elsif kind='VISIT_PASS_CHECK' then select * into i from mdac_retry_app_20261027.claim_visit_pass_check_item(b.id,wid);
  else select * into i from mdac_retry_app_20261027.claim_gmail_pin_item(b.id,wid); end if;
  if i.attempt_count<>3 then raise exception '% attempt history lost',kind; end if;
  perform set_config('request.headers',jsonb_build_object('x-mdac-protocol','2','x-mdac-batch-token',b.claim_token,'x-mdac-item-token',i.claim_token)::text,true);
  if kind='REGISTRATION_CHECK' then
   perform mdac_retry_app_20261027.heartbeat_registration_check(wid,b.id,i.id,900,'BUSY','ISOLATED','retry-test');
   perform mdac_retry_app_20261027.finish_registration_check_worker(p_item_id=>i.id,p_worker_id=>wid,p_outcome=>'FOUND',p_raw_summary=>'{"isolated_provider":true,"result_confirmed":true}');
   select count(*) into n from mdac_retry_app_20261027.registration_checks where batch_item_id=i.id and case_id=i.case_id;
  elsif kind='VISIT_PASS_CHECK' then
   perform mdac_retry_app_20261027.heartbeat_visit_pass_check(wid,b.id,i.id,900,'BUSY','ISOLATED','retry-test');
   perform mdac_retry_app_20261027.finish_visit_pass_check_worker(p_item_id=>i.id,p_worker_id=>wid,p_outcome=>'FOUND',p_raw_summary=>'{"isolated_provider":true,"result_confirmed":true}');
   select count(*) into n from mdac_retry_app_20261027.visit_pass_checks where batch_item_id=i.id and case_id=i.case_id;
  else
   perform mdac_retry_app_20261027.heartbeat_gmail_pin(wid,b.id,i.id,900,'BUSY','ISOLATED','retry-test');
   perform mdac_retry_app_20261027.finish_gmail_pin_item(p_item_id=>i.id,p_worker_id=>wid,p_pin_status=>'RECEIVED',p_email_message_id=>'isolated-message-'||i.id::text,p_pin_value=>'ISOLATED-PIN',p_raw_summary=>'{"isolated_provider":true}');
   select count(*) into n from mdac_retry_app_20261027.email_pin_records where batch_item_id=i.id and case_id=i.case_id;
  end if;
  if n<>1 or not exists(select 1 from mdac_retry_app_20261027.automation_items where id=i.id and status::text='SUCCEEDED' and case_id=i.case_id) then raise exception '% result or case mismatch',kind; end if;
  insert into mdac_retry_app_20261027.test_checks values('full_constraints_'||kind||'_retry_claim_heartbeat_finish_case_preserved',true);
 end loop;
end $$;
commit;
