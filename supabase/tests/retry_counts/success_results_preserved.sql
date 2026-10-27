-- Test real result rows as well as item states; all rows are synthetic.
begin;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare cid uuid; pid uuid; cs uuid; begin
 insert into mdac_retry_app_20261027.customers(full_name,date_of_birth,place_of_birth,passport_number,nationality,gender,passport_expiry_date,created_by)
 values('ISOLATED RESULT RETRY','1990-01-01','CHINA','TEST999999','CHN','男','2035-01-01','11111111-1111-4111-8111-111111111111') returning id into cid;
 insert into mdac_retry_app_20261027.passports(customer_id,passport_number,passport_expiry_date,created_by)
 values(cid,'TEST999999','2035-01-01','11111111-1111-4111-8111-111111111111') returning id into pid;
 insert into mdac_retry_app_20261027.customer_cases(customer_id,passport_id,order_no,created_by)
 values(cid,pid,'AA999999','11111111-1111-4111-8111-111111111111') returning id into cs;
 insert into mdac_retry_app_20261027.test_context values('result_safe_customer',cid),('result_safe_case',cs);
end $$;
insert into mdac_retry_app_20261027.automation_batches(id,task_type,created_by,entry_date,exit_date,attempt_count)
values('a1000000-0000-4000-8000-000000000004','MDAC_REGISTRATION','11111111-1111-4111-8111-111111111111','2030-01-01','2030-01-02',1);
insert into mdac_retry_app_20261027.automation_items(batch_id,customer_id,case_id,status,attempt_count,result_unknown,submission_started_at)
select 'a1000000-0000-4000-8000-000000000004',
 case when status::text='FAILED' then (select value from mdac_retry_app_20261027.test_context where key='result_safe_customer') else customer_id end,
 case when status::text='FAILED' then (select value from mdac_retry_app_20261027.test_context where key='result_safe_case') else case_id end,
 status,attempt_count,false,submission_started_at
from mdac_retry_app_20261027.test_item_before;
insert into mdac_retry_app_20261027.mdac_registrations(customer_id,case_id,batch_item_id,entry_date,exit_date,registration_status,registration_no,raw_summary)
select customer_id,case_id,id,'2030-01-01','2030-01-02','SUCCEEDED','ISOLATED-SUCCESS-'||id::text,'{"isolated_provider":true,"submitted":true,"result_confirmed":true}'
from mdac_retry_app_20261027.automation_items
where batch_id='a1000000-0000-4000-8000-000000000004' and status::text='SUCCEEDED';
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $$ declare before_results jsonb; after_results jsonb; begin
 select jsonb_agg(to_jsonb(r) order by r.id) into before_results
 from mdac_retry_app_20261027.mdac_registrations r join mdac_retry_app_20261027.automation_items i on i.id=r.batch_item_id
 where i.batch_id='a1000000-0000-4000-8000-000000000004';
 if jsonb_array_length(before_results)<>19 then raise exception 'Missing success result fixtures'; end if;
 perform mdac_retry_app_20261027.requeue_automation_batch('a1000000-0000-4000-8000-000000000004');
 select jsonb_agg(to_jsonb(r) order by r.id) into after_results
 from mdac_retry_app_20261027.mdac_registrations r join mdac_retry_app_20261027.automation_items i on i.id=r.batch_item_id
 where i.batch_id='a1000000-0000-4000-8000-000000000004';
 if before_results is distinct from after_results then raise exception 'Retry changed existing successful registrations'; end if;
 if (select count(*) from mdac_retry_app_20261027.automation_items where batch_id='a1000000-0000-4000-8000-000000000004' and status::text='QUEUED')<>1 then raise exception 'Successful item requeued'; end if;
 insert into mdac_retry_app_20261027.test_checks values('nineteen_success_result_records_bytewise_preserved',true);
end $$;
commit;
