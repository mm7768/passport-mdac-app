-- Coordinated emergency rollback only. Reverting the Order guard must NOT
-- reopen older purge endpoints. This rollback intentionally keeps the strict
-- Owner assertion and revokes ALL client EXECUTE on public/private purge RPCs.
-- First restore any Website trash records. A later reviewed migration is
-- required to re-enable permanent deletion, even if Website is rolled back.
begin;
do $$ declare v_archived boolean; begin
  if exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='customers'
      and column_name='website_archived_at') then
    execute 'select exists(select 1 from public.customers where website_archived_at is not null)
      or exists(select 1 from public.customer_cases where website_archived_at is not null)'
      into v_archived;
    if v_archived then
      raise exception 'Restore Website trash records before App guard rollback';
    end if;
  end if;
  if exists (select 1 from private.customer_hard_delete_jobs
    where status in ('AWAITING_STORAGE','STORAGE_CLEANED')) then
    raise exception 'Pending hard-delete job: rollback refused';
  end if;
end $$;
-- Replace callable wrappers before removing their guarded implementations.
-- An accidental later GRANT must still fail closed after this rollback.
create or replace function public.preview_customer_hard_delete(p_customer_ids uuid[])
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'permanent deletion disabled pending reviewed migration'
    using errcode = '42501';
end $$;
create or replace function public.create_customer_hard_delete_job(p_customer_ids uuid[])
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'permanent deletion disabled pending reviewed migration'
    using errcode = '42501';
end $$;
create or replace function public.mark_customer_hard_delete_storage_cleaned(p_job_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'permanent deletion disabled pending reviewed migration'
    using errcode = '42501';
end $$;
create or replace function public.fail_customer_hard_delete(p_job_id uuid,p_error_message text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'permanent deletion disabled pending reviewed migration'
    using errcode = '42501';
end $$;
create or replace function public.complete_customer_hard_delete(p_job_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'permanent deletion disabled pending reviewed migration'
    using errcode = '42501';
end $$;
drop trigger customer_hard_delete_job_eligibility on private.customer_hard_delete_jobs;
drop trigger pending_hard_delete_case_guard on public.customer_cases;
drop trigger pending_hard_delete_passport_guard on public.passports;
drop trigger pending_hard_delete_item_guard on public.automation_items;
drop trigger pending_hard_delete_mdac_guard on public.mdac_registrations;
drop trigger pending_hard_delete_pin_guard on public.email_pin_records;
drop trigger pending_hard_delete_registration_guard on public.registration_checks;
drop trigger pending_hard_delete_visit_pass_guard on public.visit_pass_checks;
drop trigger pending_hard_delete_ocr_guard on public.ocr_results;
drop function private.assert_hard_delete_job_eligible();
drop function private.guard_pending_hard_delete_reference();
drop function private.guard_pending_hard_delete_work();
drop function private.preview_customer_hard_delete_internal(uuid[],uuid);
drop function private.complete_customer_hard_delete_internal(uuid,uuid);
alter function private.preview_customer_hard_delete_internal_before_order_guard(uuid[],uuid)
  rename to preview_customer_hard_delete_internal;
alter function private.complete_customer_hard_delete_internal_before_order_guard(uuid,uuid)
  rename to complete_customer_hard_delete_internal;
revoke all on function private.preview_customer_hard_delete_internal(uuid[],uuid),
  private.create_customer_hard_delete_job_internal(uuid[],uuid),
  private.mark_customer_hard_delete_storage_cleaned_internal(uuid,uuid),
  private.fail_customer_hard_delete_internal(uuid,text,uuid),
  private.complete_customer_hard_delete_internal(uuid,uuid),
  private.assert_customer_delete_actor(uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.preview_customer_hard_delete(uuid[]),
  public.create_customer_hard_delete_job(uuid[]),
  public.mark_customer_hard_delete_storage_cleaned(uuid),
  public.fail_customer_hard_delete(uuid,text),
  public.complete_customer_hard_delete(uuid)
  from public,anon,authenticated,service_role;
commit;
