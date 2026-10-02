-- App is the single source of truth for hard-delete functions. A Customer with
-- any Order must never reach Storage cleanup, including archived/CANCEL Orders.
-- This common assertion is called by every private lifecycle implementation,
-- including the renamed pre-guard implementations below. Never trust p_actor.
create or replace function private.assert_customer_delete_actor(p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_actor is null or p_actor is distinct from auth.uid() or not exists (
    select 1 from public.profiles p
    where p.id = p_actor and p.role = 'OWNER' and p.access_mode = 'FULL'
      and p.is_active and p.deleted_at is null
      and (p.access_expires_at is null or p.access_expires_at > now())
  ) then
    raise exception 'active full-access Owner required for permanent deletion'
      using errcode = '42501';
  end if;
end $$;
revoke all on function private.assert_customer_delete_actor(uuid)
  from public,anon,authenticated,service_role;

alter function private.preview_customer_hard_delete_internal(uuid[],uuid)
  rename to preview_customer_hard_delete_internal_before_order_guard;

create function private.preview_customer_hard_delete_internal(
  p_customer_ids uuid[], p_actor uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_preview jsonb; v_rows jsonb := '[]'::jsonb; v_row jsonb;
  v_reasons jsonb; v_id uuid;
begin
  perform private.assert_customer_delete_actor(p_actor);
  v_preview := private.preview_customer_hard_delete_internal_before_order_guard(
    p_customer_ids,p_actor);
  for v_row in select value from jsonb_array_elements(v_preview -> 'rows') loop
    v_id := (v_row ->> 'customer_id')::uuid;
    v_reasons := coalesce(v_row -> 'blocked_reasons','[]'::jsonb);
    if exists (select 1 from public.customer_cases where customer_id = v_id
      or source_customer_id = v_id) then
      v_reasons := v_reasons || '"HAS_ORDER"'::jsonb;
    end if;
    v_row := jsonb_set(v_row,'{record_counts}',
      coalesce(v_row -> 'record_counts','{}'::jsonb) || jsonb_build_object(
        'orders',(select count(*) from public.customer_cases
          where customer_id = v_id or source_customer_id = v_id)));
    if exists (select 1 from public.passports where source_customer_id = v_id
      and customer_id is distinct from v_id) then
      v_reasons := v_reasons || '"SOURCE_PASSPORT_REFERENCE"'::jsonb;
    end if;
    v_row := jsonb_set(v_row,'{blocked_reasons}',v_reasons);
    v_row := jsonb_set(v_row,'{can_delete}',
      to_jsonb(coalesce((v_row ->> 'exists')::boolean,false)
        and jsonb_array_length(v_reasons)=0));
    v_rows := v_rows || jsonb_build_array(v_row);
  end loop;
  return jsonb_set(v_preview,'{rows}',v_rows);
end $$;

-- Recheck under Customer row locks before a job is created and paths are frozen.
create function private.assert_hard_delete_job_eligible() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); v_preview jsonb;
begin
  perform private.assert_customer_delete_actor(v_actor);
  if v_actor is distinct from new.created_by then
    raise exception 'delete job actor mismatch' using errcode = '42501';
  end if;
  perform 1 from public.customers where id = any(new.customer_ids) order by id for update;
  v_preview := private.preview_customer_hard_delete_internal(new.customer_ids,v_actor);
  if exists (select 1 from jsonb_array_elements(v_preview -> 'rows') r
    where not coalesce((r ->> 'can_delete')::boolean,false)) then
    raise exception 'Customer delete blocked by Order or related records before Storage cleanup: %',
      v_preview -> 'rows' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger customer_hard_delete_job_eligibility
  before insert on private.customer_hard_delete_jobs for each row
  execute function private.assert_hard_delete_job_eligible();

-- A pending job reserves the Customer until completion/failure. This also
-- prevents an Order being created after a valid preview but before Storage work.
create function private.guard_pending_hard_delete_reference() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_customer_id uuid;
begin
  v_customer_id := new.customer_id;
  if v_customer_id is not null then
    perform 1 from public.customers where id = v_customer_id for update;
    if exists (select 1 from private.customer_hard_delete_jobs j
      where v_customer_id = any(j.customer_ids)
        and j.status in ('AWAITING_STORAGE','STORAGE_CLEANED')) then
      raise exception 'Customer has a pending permanent-delete job'
        using errcode = 'P0001';
    end if;
  end if;
  if new.source_customer_id is not null
     and new.source_customer_id is distinct from v_customer_id then
    perform 1 from public.customers where id = new.source_customer_id for update;
    if exists (select 1 from private.customer_hard_delete_jobs j
      where new.source_customer_id = any(j.customer_ids)
        and j.status in ('AWAITING_STORAGE','STORAGE_CLEANED')) then
      raise exception 'Source Customer has a pending permanent-delete job'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
create trigger pending_hard_delete_case_guard before insert or update of customer_id,source_customer_id
  on public.customer_cases for each row execute function private.guard_pending_hard_delete_reference();
create trigger pending_hard_delete_passport_guard before insert or update of customer_id,source_customer_id
  on public.passports for each row execute function private.guard_pending_hard_delete_reference();

create function private.guard_pending_hard_delete_work() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_customer_id uuid;
begin
  if tg_table_name = 'ocr_results' then
    v_customer_id := new.created_customer_id;
  else
    v_customer_id := new.customer_id;
  end if;
  if v_customer_id is null then return new; end if;
  perform 1 from public.customers where id = v_customer_id for update;
  if exists (select 1 from private.customer_hard_delete_jobs j
    where v_customer_id = any(j.customer_ids)
      and j.status in ('AWAITING_STORAGE','STORAGE_CLEANED')) then
    raise exception 'Customer has a pending permanent-delete job'
      using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger pending_hard_delete_item_guard before insert or update on public.automation_items
  for each row execute function private.guard_pending_hard_delete_work();
create trigger pending_hard_delete_mdac_guard before insert or update on public.mdac_registrations
  for each row execute function private.guard_pending_hard_delete_work();
create trigger pending_hard_delete_pin_guard before insert or update on public.email_pin_records
  for each row execute function private.guard_pending_hard_delete_work();
create trigger pending_hard_delete_registration_guard before insert or update on public.registration_checks
  for each row execute function private.guard_pending_hard_delete_work();
create trigger pending_hard_delete_visit_pass_guard before insert or update on public.visit_pass_checks
  for each row execute function private.guard_pending_hard_delete_work();
create trigger pending_hard_delete_ocr_guard before insert or update on public.ocr_results
  for each row execute function private.guard_pending_hard_delete_work();

-- Completion must repeat eligibility even if an older job already exists.
alter function private.complete_customer_hard_delete_internal(uuid,uuid)
  rename to complete_customer_hard_delete_internal_before_order_guard;
create function private.complete_customer_hard_delete_internal(
  p_job_id uuid,p_actor uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_ids uuid[]; v_preview jsonb;
begin
  perform private.assert_customer_delete_actor(p_actor);
  select customer_ids into v_ids from private.customer_hard_delete_jobs
    where id = p_job_id and created_by = p_actor for update;
  if v_ids is null then raise exception 'delete job not found' using errcode = 'P0002'; end if;
  perform 1 from public.customers where id = any(v_ids) order by id for update;
  v_preview := private.preview_customer_hard_delete_internal(v_ids,p_actor);
  if exists (select 1 from jsonb_array_elements(v_preview -> 'rows') r
    where not coalesce((r ->> 'can_delete')::boolean,false)) then
    raise exception 'Customer delete blocked by Order or related records: %',
      v_preview -> 'rows' using errcode = 'P0001';
  end if;
  return private.complete_customer_hard_delete_internal_before_order_guard(
    p_job_id,p_actor);
end $$;

create or replace function public.preview_customer_hard_delete(p_customer_ids uuid[])
returns jsonb language sql security invoker set search_path = '' as $$
  select private.preview_customer_hard_delete_internal(p_customer_ids,auth.uid());
$$;
create or replace function public.create_customer_hard_delete_job(p_customer_ids uuid[])
returns jsonb language sql security invoker set search_path = '' as $$
  select private.create_customer_hard_delete_job_internal(p_customer_ids,auth.uid());
$$;
create or replace function public.mark_customer_hard_delete_storage_cleaned(p_job_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.mark_customer_hard_delete_storage_cleaned_internal(p_job_id,auth.uid());
$$;
create or replace function public.fail_customer_hard_delete(p_job_id uuid,p_error_message text)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.fail_customer_hard_delete_internal(p_job_id,p_error_message,auth.uid());
$$;
create or replace function public.complete_customer_hard_delete(p_job_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.complete_customer_hard_delete_internal(p_job_id,auth.uid());
$$;

revoke all on function private.preview_customer_hard_delete_internal(uuid[],uuid),
  private.create_customer_hard_delete_job_internal(uuid[],uuid),
  private.mark_customer_hard_delete_storage_cleaned_internal(uuid,uuid),
  private.fail_customer_hard_delete_internal(uuid,text,uuid),
  private.complete_customer_hard_delete_internal(uuid,uuid),
  private.assert_hard_delete_job_eligible(),
  private.guard_pending_hard_delete_reference(),
  private.guard_pending_hard_delete_work() from public,anon,authenticated,service_role;
grant execute on function private.preview_customer_hard_delete_internal(uuid[],uuid),
  private.create_customer_hard_delete_job_internal(uuid[],uuid),
  private.mark_customer_hard_delete_storage_cleaned_internal(uuid,uuid),
  private.fail_customer_hard_delete_internal(uuid,text,uuid),
  private.complete_customer_hard_delete_internal(uuid,uuid) to authenticated;
-- Renamed implementations are private plumbing, callable only by the wrappers.
revoke all on function private.preview_customer_hard_delete_internal_before_order_guard(uuid[],uuid),
  private.complete_customer_hard_delete_internal_before_order_guard(uuid,uuid)
  from public,anon,authenticated,service_role;

revoke all on function public.preview_customer_hard_delete(uuid[]),
  public.create_customer_hard_delete_job(uuid[]),
  public.mark_customer_hard_delete_storage_cleaned(uuid),
  public.fail_customer_hard_delete(uuid,text),
  public.complete_customer_hard_delete(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.preview_customer_hard_delete(uuid[]),
  public.create_customer_hard_delete_job(uuid[]),
  public.mark_customer_hard_delete_storage_cleaned(uuid),
  public.fail_customer_hard_delete(uuid,text),
  public.complete_customer_hard_delete(uuid) to authenticated;
