-- Reinitialize only the unstarted synthetic fixture for the final RPC revision.
begin;
do $$ begin
 if exists(select 1 from mdac_retry_app_20261027.automation_items where batch_id='a1000000-0000-4000-8000-000000000004' and status::text='QUEUED' and (external_started_at is not null or submission_started_at is not null or locked_by is not null)) then raise exception 'Fixture is already in flight'; end if;
 update mdac_retry_app_20261027.automation_items set status='FAILED'
 where batch_id='a1000000-0000-4000-8000-000000000004' and status::text='QUEUED';
end $$;
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',true);
do $$ declare before_results jsonb; after_results jsonb; begin
 select jsonb_agg(to_jsonb(r) order by r.id) into before_results from mdac_retry_app_20261027.mdac_registrations r join mdac_retry_app_20261027.automation_items i on i.id=r.batch_item_id where i.batch_id='a1000000-0000-4000-8000-000000000004';
 perform mdac_retry_app_20261027.requeue_automation_batch('a1000000-0000-4000-8000-000000000004');
 select jsonb_agg(to_jsonb(r) order by r.id) into after_results from mdac_retry_app_20261027.mdac_registrations r join mdac_retry_app_20261027.automation_items i on i.id=r.batch_item_id where i.batch_id='a1000000-0000-4000-8000-000000000004';
 if before_results is distinct from after_results or jsonb_array_length(before_results)<>19 then raise exception 'Successful results were changed'; end if;
 insert into mdac_retry_app_20261027.test_checks values('final_rpc_owner_retry_and_success_results_preserved',true);
end $$;
commit;
