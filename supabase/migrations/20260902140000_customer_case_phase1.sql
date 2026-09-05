-- Phase 1: additive Customer / Passport / Case foundation.
-- This migration intentionally keeps every legacy column and customer_id FK.

do $$ begin
  create type public.customer_type as enum ('A', 'STANDARD');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.customer_retention_policy as enum ('LONG_TERM', 'STANDARD_6_MONTHS');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.customer_status as enum ('ACTIVE', 'INACTIVE', 'DELETED');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.case_status as enum (
    'NEW','READY_FOR_MDAC','MDAC_PROCESSING','MDAC_COMPLETED',
    'WAITING_PIN','PIN_READY','WAITING_REGISTRATION','REGISTRATION_COMPLETED',
    'WAITING_VISIT_PASS','VISIT_PASS_COMPLETED','COMPLETED',
    'ACTION_REQUIRED','ARCHIVED','CANCELLED'
  );
exception when duplicate_object then null; end $$;
do $$ begin
  create type private.customer_pin_status as enum ('UNVERIFIED','VERIFIED','INVALID','REFRESH_REQUIRED');
exception when duplicate_object then null; end $$;

alter table public.customers
  add column if not exists customer_type public.customer_type not null default 'STANDARD',
  add column if not exists retention_policy public.customer_retention_policy not null default 'STANDARD_6_MONTHS',
  add column if not exists last_active_at timestamptz,
  add column if not exists customer_status public.customer_status not null default 'ACTIVE';

update public.customers
set last_active_at = coalesce(last_active_at, updated_at, created_at),
    customer_status = case when deleted_at is null then 'ACTIVE'::public.customer_status else 'DELETED'::public.customer_status end
where last_active_at is null
   or customer_status <> case when deleted_at is null then 'ACTIVE'::public.customer_status else 'DELETED'::public.customer_status end;

create table if not exists public.passports (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  passport_number text not null,
  passport_expiry_date date not null,
  passport_image_path text,
  is_active boolean not null default true,
  source_customer_id uuid unique references public.customers(id) on delete restrict,
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint passports_number_not_blank check (nullif(trim(passport_number),'') is not null)
);

create unique index if not exists passports_one_active_per_customer_idx
  on public.passports(customer_id) where is_active;
create index if not exists passports_customer_id_idx on public.passports(customer_id);
create index if not exists passports_normalized_number_idx
  on public.passports((upper(regexp_replace(passport_number,'[^A-Z0-9]','','g'))));
create index if not exists passports_created_by_idx on public.passports(created_by);
create index if not exists passports_updated_by_idx on public.passports(updated_by);

create table if not exists public.customer_cases (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  passport_id uuid not null references public.passports(id) on delete restrict,
  arrival_date date,
  departure_date date,
  case_status public.case_status not null default 'NEW',
  completed_at timestamptz,
  archive_at timestamptz,
  source_customer_id uuid unique references public.customers(id) on delete restrict,
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_cases_dates_valid check (
    arrival_date is null or departure_date is null or departure_date >= arrival_date
  )
);

create index if not exists customer_cases_customer_id_idx on public.customer_cases(customer_id);
create index if not exists customer_cases_passport_id_idx on public.customer_cases(passport_id);
create index if not exists customer_cases_status_idx on public.customer_cases(case_status);
create index if not exists customer_cases_archive_at_idx on public.customer_cases(archive_at) where archive_at is not null;
create index if not exists customer_cases_created_by_idx on public.customer_cases(created_by);
create index if not exists customer_cases_updated_by_idx on public.customer_cases(updated_by);

create table if not exists private.customer_mdac_profiles (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null unique references public.customers(id) on delete restrict,
  pin_value text,
  pin_status private.customer_pin_status not null default 'UNVERIFIED',
  last_verified_at timestamptz,
  source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_mdac_profiles_verified_pin check (
    pin_status <> 'VERIFIED' or nullif(trim(pin_value),'') is not null
  )
);
create index if not exists customer_mdac_profiles_customer_id_idx
  on private.customer_mdac_profiles(customer_id);

alter table public.automation_items add column if not exists case_id uuid;
alter table public.mdac_registrations add column if not exists case_id uuid;
alter table public.registration_checks add column if not exists case_id uuid;
alter table public.visit_pass_checks add column if not exists case_id uuid;
alter table public.email_pin_records add column if not exists case_id uuid;

do $$ begin
  alter table public.automation_items add constraint automation_items_case_id_fkey
    foreign key (case_id) references public.customer_cases(id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.mdac_registrations add constraint mdac_registrations_case_id_fkey
    foreign key (case_id) references public.customer_cases(id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.registration_checks add constraint registration_checks_case_id_fkey
    foreign key (case_id) references public.customer_cases(id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.visit_pass_checks add constraint visit_pass_checks_case_id_fkey
    foreign key (case_id) references public.customer_cases(id) on delete restrict;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.email_pin_records add constraint email_pin_records_case_id_fkey
    foreign key (case_id) references public.customer_cases(id) on delete set null;
exception when duplicate_object then null; end $$;

create index if not exists automation_items_case_id_idx on public.automation_items(case_id);
create index if not exists mdac_registrations_case_id_idx on public.mdac_registrations(case_id);
create index if not exists registration_checks_case_id_idx on public.registration_checks(case_id);
create index if not exists visit_pass_checks_case_id_idx on public.visit_pass_checks(case_id);
create index if not exists email_pin_records_case_id_idx on public.email_pin_records(case_id);

insert into public.passports (
  customer_id,passport_number,passport_expiry_date,passport_image_path,
  is_active,source_customer_id,created_by,updated_by,created_at,updated_at
)
select c.id,c.passport_number,c.passport_expiry_date,c.passport_image_path,
       true,c.id,c.created_by,c.updated_by,c.created_at,c.updated_at
from public.customers c
where c.deleted_at is null
on conflict (source_customer_id) do nothing;

insert into public.customer_cases (
  customer_id,passport_id,case_status,source_customer_id,
  created_by,updated_by,created_at,updated_at
)
select c.id,p.id,
  case c.business_status::text
    when 'MDAC_REGISTERING' then 'MDAC_PROCESSING'::public.case_status
    when 'MDAC_REGISTERED' then 'MDAC_COMPLETED'::public.case_status
    when 'PIN_PENDING' then 'WAITING_PIN'::public.case_status
    when 'PIN_RECEIVED' then 'PIN_READY'::public.case_status
    when 'REGISTRATION_CHECKED' then 'REGISTRATION_COMPLETED'::public.case_status
    when 'VISIT_PASS_CHECKED' then 'VISIT_PASS_COMPLETED'::public.case_status
    when 'ACTION_REQUIRED' then 'ACTION_REQUIRED'::public.case_status
    when 'ARCHIVED' then 'ARCHIVED'::public.case_status
    else 'NEW'::public.case_status
  end,
  c.id,c.created_by,c.updated_by,c.created_at,c.updated_at
from public.customers c
join public.passports p on p.source_customer_id=c.id
where c.deleted_at is null
on conflict (source_customer_id) do nothing;

update public.automation_items x set case_id=cc.id
from public.customer_cases cc where x.case_id is null and x.customer_id=cc.customer_id;
update public.mdac_registrations x set case_id=cc.id
from public.customer_cases cc where x.case_id is null and x.customer_id=cc.customer_id;
update public.registration_checks x set case_id=cc.id
from public.customer_cases cc where x.case_id is null and x.customer_id=cc.customer_id;
update public.visit_pass_checks x set case_id=cc.id
from public.customer_cases cc where x.case_id is null and x.customer_id=cc.customer_id;
update public.email_pin_records x set case_id=cc.id
from public.customer_cases cc where x.case_id is null and x.customer_id=cc.customer_id;

alter table public.passports enable row level security;
alter table public.customer_cases enable row level security;
alter table private.customer_mdac_profiles enable row level security;

drop policy if exists passports_select_active on public.passports;
create policy passports_select_active on public.passports for select to authenticated
  using (private.is_active_user());
drop policy if exists passports_insert_active on public.passports;
create policy passports_insert_active on public.passports for insert to authenticated
  with check (private.is_active_user() and created_by=(select auth.uid()));
drop policy if exists passports_update_active on public.passports;
create policy passports_update_active on public.passports for update to authenticated
  using (private.is_active_user()) with check (private.is_active_user());

drop policy if exists customer_cases_select_active on public.customer_cases;
create policy customer_cases_select_active on public.customer_cases for select to authenticated
  using (private.is_active_user());
drop policy if exists customer_cases_insert_active on public.customer_cases;
create policy customer_cases_insert_active on public.customer_cases for insert to authenticated
  with check (private.is_active_user() and created_by=(select auth.uid()));
drop policy if exists customer_cases_update_active on public.customer_cases;
create policy customer_cases_update_active on public.customer_cases for update to authenticated
  using (private.is_active_user()) with check (private.is_active_user());

revoke all on table public.passports from anon;
revoke all on table public.customer_cases from anon;
grant select,insert,update on table public.passports to authenticated;
grant select,insert,update on table public.customer_cases to authenticated;
revoke all on table private.customer_mdac_profiles from public,anon,authenticated;
grant all on table private.customer_mdac_profiles to service_role;

drop trigger if exists passports_set_updated_at on public.passports;
create trigger passports_set_updated_at before update on public.passports
for each row execute function public.set_updated_at();
drop trigger if exists customer_cases_set_updated_at on public.customer_cases;
create trigger customer_cases_set_updated_at before update on public.customer_cases
for each row execute function public.set_updated_at();
drop trigger if exists customer_mdac_profiles_set_updated_at on private.customer_mdac_profiles;
create trigger customer_mdac_profiles_set_updated_at before update on private.customer_mdac_profiles
for each row execute function public.set_updated_at();

do $$
declare v_active_customers integer; v_passports integer; v_cases integer;
begin
  select count(*) into v_active_customers from public.customers where deleted_at is null;
  select count(*) into v_passports from public.passports where source_customer_id is not null;
  select count(*) into v_cases from public.customer_cases where source_customer_id is not null;
  if v_passports<>v_active_customers or v_cases<>v_active_customers then
    raise exception 'phase1 backfill mismatch: active customers %, passports %, cases %',
      v_active_customers,v_passports,v_cases;
  end if;
end $$;

