begin;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare bid uuid; c uuid; cs uuid; label text; att integer; begin
 select value into c from mdac_retry_app_20261027.test_context where key='safe_customer';
 select value into cs from mdac_retry_app_20261027.test_context where key='safe_case';
 insert into mdac_retry_app_20261027.automation_batches(id,task_type,created_by,attempt_count,entry_date,exit_date)
 values('a1000000-0000-4000-8000-000000000002','MDAC_REGISTRATION','11111111-1111-4111-8111-111111111111',1,'2030-01-01','2030-01-02') returning id into bid;
 insert into mdac_retry_app_20261027.automation_items(batch_id,customer_id,case_id,customer_snapshot,status,attempt_count,result_unknown)
 select bid,o.customer_id,o.case_id,o.customer_snapshot,
  case when o.status::text='FAILED' then 'NEEDS_REVIEW' else 'SUCCEEDED' end::mdac_retry_app_20261027.automation_item_status,
  1,o.status::text='FAILED' from mdac_retry_app_20261027.test_item_before o;
 -- Simulate every legacy finish writer attempting to overwrite the count.
 update mdac_retry_app_20261027.automation_batches set success_count=999,failed_count=999 where id=bid;
 if not exists(select 1 from mdac_retry_app_20261027.automation_batches where id=bid and total_count=20 and success_count=19 and failed_count=0 and status::text='NEEDS_REVIEW') then raise exception 'Legacy writer defeated canonical counts'; end if;
 insert into mdac_retry_app_20261027.test_context values('unknown_batch',bid);
 insert into mdac_retry_app_20261027.test_checks values('review_is_not_success_and_late_writer_cannot_double_count',true);
 foreach label in array array['attempt_limit','active_lease','submitted_failure'] loop
  att:=case when label='attempt_limit' then 5 else 1 end;
  insert into mdac_retry_app_20261027.automation_batches(task_type,created_by,attempt_count,entry_date,exit_date)
  values('MDAC_REGISTRATION','11111111-1111-4111-8111-111111111111',att,'2030-01-01','2030-01-02') returning id into bid;
  insert into mdac_retry_app_20261027.automation_items(batch_id,customer_id,case_id,status,attempt_count,result_unknown,submission_started_at)
  values(bid,c,cs,'FAILED',2,false,case when label='submitted_failure' then now() else null end);
  if label='active_lease' then update mdac_retry_app_20261027.automation_batches set lease_expires_at=now()+interval '5 minutes' where id=bid; end if;
  insert into mdac_retry_app_20261027.test_context values(label,bid);
 end loop;
end $$;
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $$ declare c record; data jsonb; begin
 for c in select * from mdac_retry_app_20261027.test_context where key in ('unknown_batch','attempt_limit','active_lease','submitted_failure') loop
  begin
   perform mdac_retry_app_20261027.requeue_automation_batch(c.value);
   raise exception 'Unsafe retry unexpectedly accepted';
  exception when raise_exception then
   if sqlerrm not like 'G1/G2:%' and sqlerrm not like 'Batch attempt limit%' then raise; end if;
   insert into mdac_retry_app_20261027.test_checks values(c.key||'_retry_refused',true);
  end;
 end loop;
 data:=mdac_retry_app_20261027.get_latest_task_dashboard();
 if exists(select 1 from jsonb_array_elements(data) b where (b->>'total_count')::int<>jsonb_array_length(b->'items')) then raise exception 'Dashboard join inflated tasks'; end if;
 if exists(select 1 from jsonb_array_elements(data) b,jsonb_array_elements(b->'items') i where not(i ? 'case_id') or not(i ? 'submission_started_at')) then raise exception 'Retry phase metadata missing'; end if;
 insert into mdac_retry_app_20261027.test_checks values('dashboard_item_set_and_retry_metadata_consistent',true);
end $$;
commit;
