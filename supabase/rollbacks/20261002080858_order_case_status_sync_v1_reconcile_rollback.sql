-- Guarded emergency rollback for historical Order status reconciliation.
begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

lock table public.customer_cases,
           public.audit_logs,
           private.order_case_status_sync_v1_manifest
  in share row exclusive mode;

do $guard$
begin
  if not exists (
    select 1 from private.order_case_status_sync_v1_manifest
  ) then
    raise exception 'Order status reconciliation manifest is empty';
  end if;

  if exists (
    select 1
    from private.order_case_status_sync_v1_manifest m
    left join public.customer_cases c on c.id = m.case_id
    where c.id is null
       or c.case_status is distinct from m.reconciled_case_status
  ) then
    raise exception 'a reconciled Order changed after migration; refusing rollback';
  end if;
end
$guard$;

update public.customer_cases c
   set case_status = m.previous_case_status,
       updated_at = clock_timestamp()
  from private.order_case_status_sync_v1_manifest m
 where c.id = m.case_id
   and c.case_status = m.reconciled_case_status;

delete from public.audit_logs a
using private.order_case_status_sync_v1_manifest m
where a.entity_type = 'ORDER'
  and a.entity_id = m.case_id
  and a.action = 'ORDER_WORKFLOW_STATUS_SYNC'
  and a.created_at >= m.started_at
  and a.created_at <= m.reconciled_at;

delete from private.order_case_status_sync_v1_manifest;

commit;
