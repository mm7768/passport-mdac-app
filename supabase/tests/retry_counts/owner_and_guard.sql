-- Executes as actual PostgreSQL authenticated role, with synthetic auth.uid claims.
-- No production namespace or external service is called.
begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $$ declare b mdac_retry_app_20261027.automation_batches; x uuid; begin
 if not mdac_retry_private_20261027.is_active_user() then raise exception 'Owner fixture is not active'; end if;
 begin
  update mdac_retry_app_20261027.automation_items set status='QUEUED' where id=(select value from mdac_retry_app_20261027.test_context where key='safe_item');
  raise exception 'Direct client write unexpectedly succeeded';
 exception when insufficient_privilege then
  insert into mdac_retry_app_20261027.test_checks values('direct_patch_still_42501',true);
 end;
 b:=mdac_retry_app_20261027.requeue_automation_batch('a1000000-0000-4000-8000-000000000001');
 if b.status::text<>'QUEUED' or b.total_count<>20 or b.success_count<>19 or b.failed_count<>0 then raise exception 'Retry counters mismatch'; end if;
 if exists(select 1 from mdac_retry_app_20261027.automation_items i join mdac_retry_app_20261027.test_item_before o using(id)
  where i.case_id is distinct from o.case_id or i.customer_id<>o.customer_id or i.batch_id<>o.batch_id or i.attempt_count<>o.attempt_count) then raise exception 'Retry changed identity or history'; end if;
 if exists(select 1 from mdac_retry_app_20261027.automation_items i join mdac_retry_app_20261027.test_item_before o using(id)
  where o.status::text='SUCCEEDED' and to_jsonb(i) is distinct from to_jsonb(o)) then raise exception 'A successful item was modified'; end if;
 insert into mdac_retry_app_20261027.test_checks values('owner_retry_no_42501_and_original_ids_attempts_preserved',true),('nineteen_successes_untouched',true),('queued_counts_19_of_20',true);
 begin
  perform mdac_retry_app_20261027.requeue_automation_batch(b.id);
  raise exception 'Repeated retry unexpectedly succeeded';
 exception when raise_exception then
  if sqlerrm not like 'G1/G2:%' then raise; end if;
  insert into mdac_retry_app_20261027.test_checks values('repeat_retry_rejected_without_new_attempt',true);
 end;
end $$;
commit;
