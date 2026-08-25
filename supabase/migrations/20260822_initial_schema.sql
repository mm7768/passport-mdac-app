-- Passport MDAC Desk initial schema
-- Safe baseline for the empty project xdmcxhvdqsbcqedfprcy.
-- This migration intentionally does not seed passwords, secrets, passport data, or PINs.

create extension if not exists pgcrypto;

create type public.user_role as enum ('OWNER', 'OPERATOR');
create type public.ocr_source_type as enum ('IMAGE', 'PDF');
create type public.ocr_batch_status as enum ('UPLOADED', 'PROCESSING', 'REVIEW_REQUIRED', 'READY_TO_CREATE', 'CREATED', 'FAILED');
create type public.ocr_result_status as enum ('REVIEW_REQUIRED', 'READY_TO_CREATE', 'CREATED', 'FAILED');
create type public.business_status as enum ('PENDING', 'MDAC_REGISTERING', 'MDAC_REGISTERED', 'PIN_PENDING', 'PIN_RECEIVED', 'REGISTRATION_CHECKED', 'VISIT_PASS_CHECKED', 'ACTION_REQUIRED', 'ARCHIVED');
create type public.automation_task_type as enum ('MDAC_REGISTRATION', 'GMAIL_PIN', 'REGISTRATION_CHECK', 'VISIT_PASS_CHECK');
create type public.automation_status as enum ('QUEUED', 'CLAIMED', 'RUNNING', 'SUCCEEDED', 'PARTIAL_SUCCESS', 'FAILED', 'CANCEL_REQUESTED', 'CANCELLED', 'NEEDS_REVIEW');
create type public.automation_item_status as enum ('QUEUED', 'CLAIMED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED', 'NEEDS_REVIEW');
create type public.registration_status as enum ('SUBMITTED', 'SUCCEEDED', 'FAILED', 'RESULT_UNKNOWN', 'NEEDS_REVIEW');
create type public.pin_status as enum ('RECEIVED', 'NOT_FOUND', 'NEEDS_REVIEW', 'PARSE_FAILED');
create type public.check_status as enum ('PARSED', 'UNPARSED', 'NEEDS_REVIEW', 'FAILED');
create type public.worker_status as enum ('ONLINE', 'BUSY', 'OFFLINE', 'ERROR');

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  name text not null check (length(trim(name)) between 1 and 120),
  role public.user_role not null default 'OPERATOR',
  is_active boolean not null default true,
  must_change_password boolean not null default true,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ocr_batches (
  id uuid primary key default gen_random_uuid(),
  uploaded_by uuid not null references public.profiles(id) on delete restrict,
  source_type public.ocr_source_type not null,
  file_path text not null check (length(trim(file_path)) > 0),
  status public.ocr_batch_status not null default 'UPLOADED',
  total_results integer not null default 0 check (total_results >= 0),
  processed_results integer not null default 0 check (processed_results >= 0),
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ocr_results (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.ocr_batches(id) on delete cascade,
  page_index integer not null default 0 check (page_index >= 0),
  segment_index integer not null default 0 check (segment_index >= 0),
  raw_result jsonb not null default '{}'::jsonb,
  extracted_data jsonb not null default '{}'::jsonb,
  confidence numeric(5,4) check (confidence is null or (confidence >= 0 and confidence <= 1)),
  status public.ocr_result_status not null default 'REVIEW_REQUIRED',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_customer_id uuid,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id, page_index, segment_index)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (length(trim(full_name)) between 1 and 160),
  date_of_birth date not null,
  place_of_birth text not null check (length(trim(place_of_birth)) between 1 and 160),
  passport_number text not null check (length(trim(passport_number)) between 2 and 32),
  nationality text not null check (length(trim(nationality)) between 2 and 80),
  gender text not null check (gender in ('男', '女', '1', '2')),
  passport_expiry_date date not null,
  passport_image_path text,
  business_status public.business_status not null default 'PENDING',
  created_by uuid not null references public.profiles(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint passport_expiry_after_birth check (passport_expiry_date > date_of_birth)
);

create table public.automation_batches (
  id uuid primary key default gen_random_uuid(),
  task_type public.automation_task_type not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  status public.automation_status not null default 'QUEUED',
  total_count integer not null default 0 check (total_count >= 0),
  success_count integer not null default 0 check (success_count >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  entry_date date,
  exit_date date,
  idempotency_key text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mdac_dates_are_ordered check (task_type <> 'MDAC_REGISTRATION' or (entry_date is not null and exit_date is not null and exit_date >= entry_date)),
  constraint counts_do_not_exceed_total check (success_count + failed_count <= total_count)
);

create table public.automation_items (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.automation_batches(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  customer_snapshot jsonb not null default '{}'::jsonb,
  status public.automation_item_status not null default 'QUEUED',
  attempt_count integer not null default 0 check (attempt_count >= 0),
  locked_by text,
  locked_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  error_code text,
  error_message text,
  result_unknown boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id, customer_id)
);

create table public.mdac_registrations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  batch_item_id uuid not null unique references public.automation_items(id) on delete restrict,
  entry_date date not null,
  exit_date date not null,
  registration_no text,
  registration_status public.registration_status not null,
  raw_summary jsonb not null default '{}'::jsonb,
  screenshot_path text,
  submitted_at timestamptz,
  result_confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mdac_result_dates_are_ordered check (exit_date >= entry_date)
);

create table public.email_pin_records (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  batch_item_id uuid not null unique references public.automation_items(id) on delete restrict,
  email_message_id text unique,
  sender text,
  subject text,
  matched_by text,
  pin_value text,
  match_confidence numeric(5,4) check (match_confidence is null or (match_confidence >= 0 and match_confidence <= 1)),
  status public.pin_status not null,
  raw_summary jsonb not null default '{}'::jsonb,
  received_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.registration_checks (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  batch_item_id uuid not null unique references public.automation_items(id) on delete restrict,
  checked_at timestamptz,
  result_status public.check_status not null,
  raw_summary jsonb not null default '{}'::jsonb,
  normalized_status text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.visit_pass_checks (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  batch_item_id uuid not null unique references public.automation_items(id) on delete restrict,
  checked_at timestamptz,
  result_status public.check_status not null,
  raw_summary jsonb not null default '{}'::jsonb,
  normalized_status text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.worker_heartbeats (
  worker_id text primary key,
  hostname text not null,
  version text not null,
  status public.worker_status not null,
  current_batch_id uuid references public.automation_batches(id) on delete set null,
  last_seen_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null check (length(trim(action)) between 1 and 100),
  entity_type text not null check (length(trim(entity_type)) between 1 and 80),
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.ocr_results
  add constraint ocr_result_created_customer_fk
  foreign key (created_customer_id) references public.customers(id) on delete set null;

create unique index customers_active_passport_uq on public.customers (upper(trim(passport_number))) where deleted_at is null;
create unique index automation_batch_idempotency_uq on public.automation_batches (created_by, idempotency_key) where idempotency_key is not null;
create unique index automation_active_customer_uq on public.automation_items (customer_id) where status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW');
create index customers_business_status_idx on public.customers (business_status) where deleted_at is null;
create index customers_created_at_idx on public.customers (created_at desc);
create index automation_batches_created_at_idx on public.automation_batches (created_at desc);
create index automation_items_queue_idx on public.automation_items (status, created_at);
create index audit_logs_created_at_idx on public.audit_logs (created_at desc);
create index worker_heartbeats_last_seen_idx on public.worker_heartbeats (last_seen_at desc);

create or replace function public.current_profile()
returns public.profiles
language sql
security definer
stable
set search_path = public
as $$
  select p.* from public.profiles p where p.id = auth.uid() limit 1;
$$;

create or replace function public.is_active_user()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active = true and p.deleted_at is null
  );
$$;

create or replace function public.is_owner()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'OWNER' and p.is_active = true and p.deleted_at is null
  );
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, role, is_active, must_change_password)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), split_part(coalesce(new.email, 'new-user'), '@', 1)),
    'OPERATOR',
    true,
    true
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.sync_automation_batch_counts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_batch uuid;
  total_items integer;
  succeeded_items integer;
  failed_items integer;
  active_items integer;
  next_status public.automation_status;
begin
  target_batch := coalesce(new.batch_id, old.batch_id);
  select count(*)::integer,
         count(*) filter (where status = 'SUCCEEDED')::integer,
         count(*) filter (where status = 'FAILED')::integer,
         count(*) filter (where status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW'))::integer
    into total_items, succeeded_items, failed_items, active_items
    from public.automation_items
   where batch_id = target_batch;

  select status into next_status from public.automation_batches where id = target_batch;
  if total_items > 0 then
    if active_items > 0 then
      if exists (select 1 from public.automation_items where batch_id = target_batch and status in ('CLAIMED', 'RUNNING')) then
        next_status := 'RUNNING';
      else
        next_status := 'QUEUED';
      end if;
    elsif failed_items = total_items then
      next_status := 'FAILED';
    elsif succeeded_items = total_items then
      next_status := 'SUCCEEDED';
    elsif succeeded_items + failed_items = total_items then
      next_status := 'PARTIAL_SUCCESS';
    end if;
  end if;

  update public.automation_batches
     set total_count = total_items,
         success_count = succeeded_items,
         failed_count = failed_items,
         status = next_status,
         updated_at = now()
   where id = target_batch;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger automation_items_sync_batch_counts
 after insert or update of status or delete on public.automation_items
 for each row execute procedure public.sync_automation_batch_counts();

create trigger profiles_set_updated_at before update on public.profiles for each row execute procedure public.set_updated_at();
create trigger ocr_batches_set_updated_at before update on public.ocr_batches for each row execute procedure public.set_updated_at();
create trigger ocr_results_set_updated_at before update on public.ocr_results for each row execute procedure public.set_updated_at();
create trigger customers_set_updated_at before update on public.customers for each row execute procedure public.set_updated_at();
create trigger automation_batches_set_updated_at before update on public.automation_batches for each row execute procedure public.set_updated_at();
create trigger automation_items_set_updated_at before update on public.automation_items for each row execute procedure public.set_updated_at();
create trigger mdac_registrations_set_updated_at before update on public.mdac_registrations for each row execute procedure public.set_updated_at();
create trigger email_pin_records_set_updated_at before update on public.email_pin_records for each row execute procedure public.set_updated_at();
create trigger registration_checks_set_updated_at before update on public.registration_checks for each row execute procedure public.set_updated_at();
create trigger visit_pass_checks_set_updated_at before update on public.visit_pass_checks for each row execute procedure public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.ocr_batches enable row level security;
alter table public.ocr_results enable row level security;
alter table public.customers enable row level security;
alter table public.automation_batches enable row level security;
alter table public.automation_items enable row level security;
alter table public.mdac_registrations enable row level security;
alter table public.email_pin_records enable row level security;
alter table public.registration_checks enable row level security;
alter table public.visit_pass_checks enable row level security;
alter table public.worker_heartbeats enable row level security;
alter table public.audit_logs enable row level security;

create policy profiles_select_active on public.profiles for select to authenticated using (public.is_active_user() and (is_active or id = auth.uid() or public.is_owner()));
-- Profile role, activation and password flags are intentionally not client-writable.
-- OWNER account management will be implemented through a protected server operation.

create policy ocr_batches_select_active on public.ocr_batches for select to authenticated using (public.is_active_user());
create policy ocr_batches_insert_active on public.ocr_batches for insert to authenticated with check (public.is_active_user() and uploaded_by = auth.uid());
create policy ocr_batches_update_active on public.ocr_batches for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy ocr_results_select_active on public.ocr_results for select to authenticated using (public.is_active_user());
create policy ocr_results_insert_active on public.ocr_results for insert to authenticated with check (public.is_active_user());
create policy ocr_results_update_active on public.ocr_results for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy customers_select_active on public.customers for select to authenticated using (public.is_active_user() and (deleted_at is null or public.is_owner()));
create policy customers_insert_active on public.customers for insert to authenticated with check (public.is_active_user() and created_by = auth.uid());
create policy customers_update_active on public.customers for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy automation_batches_select_active on public.automation_batches for select to authenticated using (public.is_active_user());
create policy automation_batches_insert_active on public.automation_batches for insert to authenticated with check (public.is_active_user() and created_by = auth.uid());
create policy automation_batches_update_active on public.automation_batches for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy automation_items_select_active on public.automation_items for select to authenticated using (public.is_active_user());
create policy automation_items_insert_active on public.automation_items for insert to authenticated with check (public.is_active_user());
create policy automation_items_update_active on public.automation_items for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy mdac_registrations_select_active on public.mdac_registrations for select to authenticated using (public.is_active_user());
create policy mdac_registrations_insert_active on public.mdac_registrations for insert to authenticated with check (public.is_active_user());
create policy mdac_registrations_update_active on public.mdac_registrations for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy email_pin_records_select_active on public.email_pin_records for select to authenticated using (public.is_active_user());
create policy email_pin_records_insert_active on public.email_pin_records for insert to authenticated with check (public.is_active_user());
create policy email_pin_records_update_active on public.email_pin_records for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy registration_checks_select_active on public.registration_checks for select to authenticated using (public.is_active_user());
create policy registration_checks_insert_active on public.registration_checks for insert to authenticated with check (public.is_active_user());
create policy registration_checks_update_active on public.registration_checks for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy visit_pass_checks_select_active on public.visit_pass_checks for select to authenticated using (public.is_active_user());
create policy visit_pass_checks_insert_active on public.visit_pass_checks for insert to authenticated with check (public.is_active_user());
create policy visit_pass_checks_update_active on public.visit_pass_checks for update to authenticated using (public.is_active_user()) with check (public.is_active_user());

create policy worker_heartbeats_select_active on public.worker_heartbeats for select to authenticated using (public.is_active_user());
create policy audit_logs_select_active on public.audit_logs for select to authenticated using (public.is_active_user() and (public.is_owner() or actor_id = auth.uid()));
create policy audit_logs_insert_active on public.audit_logs for insert to authenticated with check (public.is_active_user() and actor_id = auth.uid());

insert into storage.buckets (id, name, public)
values ('passport-documents', 'passport-documents', false)
on conflict (id) do update set public = excluded.public;

create policy passport_documents_select_active
on storage.objects for select to authenticated
using (bucket_id = 'passport-documents' and public.is_active_user());

create policy passport_documents_insert_active
on storage.objects for insert to authenticated
with check (bucket_id = 'passport-documents' and public.is_active_user());

create policy passport_documents_update_active
on storage.objects for update to authenticated
using (bucket_id = 'passport-documents' and public.is_active_user())
with check (bucket_id = 'passport-documents' and public.is_active_user());

create policy passport_documents_delete_owner
on storage.objects for delete to authenticated
using (bucket_id = 'passport-documents' and public.is_owner());

revoke all on function public.current_profile() from public, anon;
revoke all on function public.is_active_user() from public, anon;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.current_profile() to authenticated;
grant execute on function public.is_active_user() to authenticated;
grant execute on function public.is_owner() to authenticated;

comment on table public.profiles is 'Business profile and role metadata linked to auth.users; public signup remains disabled by project policy.';
comment on table public.customers is 'Passport customer master records. Use deleted_at for soft deletion and never expose passport files publicly.';
comment on table public.automation_items is 'One customer snapshot per automation batch item. Worker must preserve result-unknown states.';
comment on column public.email_pin_records.pin_value is 'Sensitive field. Restrict client exposure further before production Gmail integration.';
-- The passport-documents bucket is private; clients must use authenticated access or short-lived signed URLs.
