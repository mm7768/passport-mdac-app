-- 20261002000000_batch_orders_latest_automation_statuses.sql
-- 补充 Batch Detail 与 Order Context 的 Case 级四段自动化状态 (MDAC, PIN, Registration, Visit Pass)

-- 1. 创建高效索引保障 Case 级别查询性能
create index if not exists mdac_registrations_case_id_created_at_idx
  on public.mdac_registrations (case_id, created_at desc)
  where case_id is not null;

create index if not exists email_pin_records_case_id_created_at_idx
  on public.email_pin_records (case_id, created_at desc)
  where case_id is not null;

create index if not exists registration_checks_case_id_created_at_idx
  on public.registration_checks (case_id, created_at desc)
  where case_id is not null;

create index if not exists visit_pass_checks_case_id_created_at_idx
  on public.visit_pass_checks (case_id, created_at desc)
  where case_id is not null;

-- 2. 升级 public.get_app_batch_orders(uuid) 返回四段式自动化状态
drop function if exists public.get_app_batch_orders(uuid);

create or replace function public.get_app_batch_orders(p_batch_id uuid)
returns table (
  membership_id uuid,
  batch_id uuid,
  order_id uuid,
  case_id uuid,
  order_no text,
  customer_id uuid,
  passport_id uuid,
  display_name text,
  passport_number text,
  business_status text,
  workflow_status text,
  priority text,
  membership_status text,
  arrival_date date,
  departure_date date,
  latest_mdac_status text,
  latest_pin_status text,
  latest_registration_status text,
  latest_visit_pass_status text
)
language plpgsql
stable
security invoker
set search_path = ''
as $function$
begin
  if auth.uid() is null or not private.is_active_user() then
    raise exception 'active authenticated user required' using errcode = '42501';
  end if;

  return query
  select
    i.id,
    b.id,
    cc.id,
    cc.id,
    cc.order_no,
    cc.customer_id,
    cc.passport_id,
    coalesce(cc.customer_snapshot ->> 'full_name', c.full_name),
    coalesce(cc.customer_snapshot ->> 'passport_number', c.passport_number),
    coalesce(cc.business_status, 'CURRENT'),
    cc.case_status::text,
    cc.priority,
    i.disposition,
    cc.arrival_date,
    cc.departure_date,
    mdac.status,
    pin.status,
    registration.status,
    visit_pass.status
  from public.operational_batches b
  join public.operational_batch_items i on i.batch_id = b.id
  join public.customer_cases cc on cc.id = i.order_id
  join public.customers c on c.id = cc.customer_id
  left join lateral (
    select m.registration_status::text as status
    from public.mdac_registrations m
    where m.case_id = cc.id
    order by m.created_at desc
    limit 1
  ) mdac on true
  left join lateral (
    select e.status::text as status
    from public.email_pin_records e
    where e.case_id = cc.id
    order by e.created_at desc
    limit 1
  ) pin on true
  left join lateral (
    select r.result_status::text as status
    from public.registration_checks r
    where r.case_id = cc.id
    order by r.created_at desc
    limit 1
  ) registration on true
  left join lateral (
    select v.result_status::text as status
    from public.visit_pass_checks v
    where v.case_id = cc.id
    order by v.created_at desc
    limit 1
  ) visit_pass on true
  where b.id = p_batch_id
    and b.status = 'OPEN'
    and i.released_at is null
  order by i.created_at, i.id;
end
$function$;

revoke execute on function public.get_app_batch_orders(uuid) from public, anon;
grant execute on function public.get_app_batch_orders(uuid) to authenticated;

-- 3. 升级 public.get_app_order_execution_context(uuid) 补齐 MDAC 状态与 ID
drop function if exists public.get_app_order_execution_context(uuid);

create or replace function public.get_app_order_execution_context(p_order_id uuid)
returns table (
  batch_id uuid,
  membership_id uuid,
  order_id uuid,
  case_id uuid,
  order_no text,
  customer_id uuid,
  passport_id uuid,
  full_name text,
  passport_number text,
  nationality text,
  date_of_birth date,
  gender text,
  passport_expiry_date date,
  arrival_date date,
  departure_date date,
  business_status text,
  workflow_status text,
  priority text,
  latest_mdac_registration_id uuid,
  latest_mdac_status text,
  latest_pin_record_id uuid,
  latest_pin_status text,
  latest_registration_check_id uuid,
  latest_registration_status text,
  latest_visit_pass_check_id uuid,
  latest_visit_pass_status text
)
language plpgsql
stable
security invoker
set search_path = ''
as $function$
begin
  if auth.uid() is null or not private.is_active_user() then
    raise exception 'active authenticated user required' using errcode = '42501';
  end if;

  return query
  select
    b.id,
    i.id,
    cc.id,
    cc.id,
    cc.order_no,
    cc.customer_id,
    cc.passport_id,
    coalesce(cc.customer_snapshot ->> 'full_name', c.full_name),
    coalesce(cc.customer_snapshot ->> 'passport_number', p.passport_number, c.passport_number),
    coalesce(cc.customer_snapshot ->> 'nationality', c.nationality),
    coalesce((cc.customer_snapshot ->> 'date_of_birth')::date, c.date_of_birth),
    coalesce(cc.customer_snapshot ->> 'gender', c.gender),
    coalesce((cc.customer_snapshot ->> 'passport_expiry_date')::date, p.passport_expiry_date, c.passport_expiry_date),
    cc.arrival_date,
    cc.departure_date,
    coalesce(cc.business_status, 'CURRENT'),
    cc.case_status::text,
    cc.priority,
    mdac.id,
    mdac.status,
    pin.id,
    pin.status,
    registration.id,
    registration.status,
    visit_pass.id,
    visit_pass.status
  from public.operational_batch_items i
  join public.operational_batches b on b.id = i.batch_id
  join public.customer_cases cc on cc.id = i.order_id
  join public.customers c on c.id = cc.customer_id
  join public.passports p on p.id = cc.passport_id
  left join lateral (
    select m.id, m.registration_status::text as status
    from public.mdac_registrations m
    where m.case_id = cc.id
    order by m.created_at desc
    limit 1
  ) mdac on true
  left join lateral (
    select e.id, e.status::text as status
    from public.email_pin_records e
    where e.case_id = cc.id
    order by e.created_at desc
    limit 1
  ) pin on true
  left join lateral (
    select r.id, r.result_status::text as status
    from public.registration_checks r
    where r.case_id = cc.id
    order by r.created_at desc
    limit 1
  ) registration on true
  left join lateral (
    select v.id, v.result_status::text as status
    from public.visit_pass_checks v
    where v.case_id = cc.id
    order by v.created_at desc
    limit 1
  ) visit_pass on true
  where cc.id = p_order_id
    and b.status = 'OPEN'
    and i.released_at is null
  limit 1;
end
$function$;

revoke execute on function public.get_app_order_execution_context(uuid) from public, anon;
grant execute on function public.get_app_order_execution_context(uuid) to authenticated;
