-- Emergency rollback for exact Order workflow synchronization primitives.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

drop trigger if exists automation_items_sync_order_status_v1
  on public.automation_items;
drop function if exists private.sync_case_status_from_automation_item_v1();
drop function if exists private.sync_case_status_from_item_v1(uuid);

commit;
