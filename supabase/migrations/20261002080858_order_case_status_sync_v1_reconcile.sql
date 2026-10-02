-- Reconcile historical strict Automation Items into authoritative Order status.
-- The private synchronizer enforces monotonic, stage-aware transitions.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '90s';

lock table public.automation_batches,
           public.automation_items,
           public.customer_cases,
           public.audit_logs
  in share row exclusive mode;

do $preflight$
begin
  if to_regprocedure('private.sync_case_status_from_item_v1(uuid)') is null then
    raise exception 'Order status sync V1 helper is missing';
  end if;

  if exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.customers'::regclass
      and t.tgname = 'customers_sync_case_status'
      and t.tgenabled <> 'D'
  ) then
    raise exception 'unsafe customer-level status trigger was re-enabled';
  end if;

  if to_regclass('private.order_case_status_sync_v1_manifest') is not null then
    raise exception 'Order status reconciliation manifest already exists';
  end if;
end
$preflight$;

create table private.order_case_status_sync_v1_manifest (
  case_id uuid primary key,
  previous_case_status public.case_status not null,
  reconciled_case_status public.case_status,
  strict_item_count integer not null,
  max_task_stage smallint not null,
  started_at timestamptz not null default clock_timestamp(),
  reconciled_at timestamptz,
  constraint order_case_status_sync_v1_item_count_check
    check (strict_item_count > 0),
  constraint order_case_status_sync_v1_stage_check
    check (max_task_stage between 1 and 4)
);

comment on table private.order_case_status_sync_v1_manifest is
  'Audit manifest for Orders whose workflow status changed during exact case_id reconciliation.';

alter table private.order_case_status_sync_v1_manifest enable row level security;
revoke all on table private.order_case_status_sync_v1_manifest
  from public, anon, authenticated, service_role;

insert into private.order_case_status_sync_v1_manifest (
  case_id,
  previous_case_status,
  strict_item_count,
  max_task_stage
)
select
  c.id,
  c.case_status,
  count(*)::integer,
  max(case b.task_type
    when 'MDAC_REGISTRATION' then 1
    when 'GMAIL_PIN' then 2
    when 'REGISTRATION_CHECK' then 3
    when 'VISIT_PASS_CHECK' then 4
  end)::smallint
from public.customer_cases c
join public.automation_items i on i.case_id = c.id
join public.automation_batches b on b.id = i.batch_id
group by c.id, c.case_status;

do $reconcile$
declare
  v_item_id uuid;
  v_before_batches bigint;
  v_before_items bigint;
begin
  select count(*) into v_before_batches from public.automation_batches;
  select count(*) into v_before_items from public.automation_items;

  for v_item_id in
    select i.id
    from public.automation_items i
    where i.case_id is not null
    order by
      coalesce(i.finished_at, i.updated_at, i.created_at),
      i.created_at,
      i.id
  loop
    perform private.sync_case_status_from_item_v1(v_item_id);
  end loop;

  update private.order_case_status_sync_v1_manifest m
     set reconciled_case_status = c.case_status,
         reconciled_at = clock_timestamp()
    from public.customer_cases c
   where c.id = m.case_id;

  delete from private.order_case_status_sync_v1_manifest
   where reconciled_case_status = previous_case_status;

  if (select count(*) from public.automation_batches) <> v_before_batches
     or (select count(*) from public.automation_items) <> v_before_items then
    raise exception 'reconciliation created or removed Automation rows';
  end if;
end
$reconcile$;

do $verify$
begin
  if exists (
    select 1
    from private.order_case_status_sync_v1_manifest m
    left join public.customer_cases c on c.id = m.case_id
    where c.id is null
       or c.case_status is distinct from m.reconciled_case_status
       or m.reconciled_case_status is null
  ) then
    raise exception 'reconciled Order status differs from the audit manifest';
  end if;

  -- A strict Case whose furthest stage is MDAC and has a successful MDAC Item
  -- must no longer remain below MDAC_COMPLETED.
  if exists (
    with strict_cases as (
      select
        i.case_id,
        max(case b.task_type
          when 'MDAC_REGISTRATION' then 1
          when 'GMAIL_PIN' then 2
          when 'REGISTRATION_CHECK' then 3
          when 'VISIT_PASS_CHECK' then 4
        end) as max_stage,
        bool_or(
          b.task_type = 'MDAC_REGISTRATION'
          and i.status = 'SUCCEEDED'
        ) as mdac_succeeded
      from public.automation_items i
      join public.automation_batches b on b.id = i.batch_id
      where i.case_id is not null
      group by i.case_id
    )
    select 1
    from strict_cases s
    join public.customer_cases c on c.id = s.case_id
    where s.max_stage = 1
      and s.mdac_succeeded
      and c.case_status not in (
        'MDAC_COMPLETED',
        'ACTION_REQUIRED',
        'COMPLETED',
        'ARCHIVED',
        'CANCELLED'
      )
  ) then
    raise exception 'a successful MDAC-only strict Order remains below MDAC_COMPLETED';
  end if;

  if exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.customers'::regclass
      and t.tgname = 'customers_sync_case_status'
      and t.tgenabled <> 'D'
  ) then
    raise exception 'unsafe customer-level status trigger changed during reconciliation';
  end if;
end
$verify$;

commit;
