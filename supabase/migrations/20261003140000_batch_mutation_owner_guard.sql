-- Forward guard for already-deployed batch RPCs. Keep the existing business
-- implementation in private; authorize against the real JWT, not p_actor.
-- Apply only after the Website profiles.access_mode migration.
create or replace function private.assert_batch_mutation_access(p_batch_ids uuid[])
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_owner boolean;
begin
  if auth.role() = 'service_role' then return true; end if;

  select p.role = 'OWNER' into v_is_owner
  from public.profiles p
  where p.id = auth.uid() and p.is_active and p.deleted_at is null
    and p.access_mode = 'FULL'
    and (p.access_expires_at is null or p.access_expires_at > now());
  if not found then
    raise exception 'active full-access user required'
      using errcode = '42501';
  end if;

  -- A stable lock order avoids deadlocks and closes the gap between the
  -- ownership check and the privileged legacy mutation.
  perform 1 from public.automation_batches b
  where b.id = any(p_batch_ids)
  order by b.id for update;
  if exists (
    select 1 from unnest(p_batch_ids) as selected(batch_id)
    left join public.automation_batches b on b.id = selected.batch_id
    where b.id is null or (not v_is_owner and b.created_by is distinct from auth.uid())
  ) then
    raise exception 'batch owner or Owner required' using errcode = '42501';
  end if;
  return v_is_owner;
end;
$$;
revoke all on function private.assert_batch_mutation_access(uuid[])
  from public, anon, authenticated, service_role;

-- The historical split body calls this helper; some deployed schemas lack it.
create or replace function private.sync_batch_status_and_counts(p_batch_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_total int; v_success int; v_failed int; v_running int;
  v_queued int; v_review int; v_status public.automation_status;
begin
  select count(*)::int,
    count(*) filter (where status in ('SUCCEEDED','NEEDS_REVIEW'))::int,
    count(*) filter (where status='FAILED')::int,
    count(*) filter (where status in ('CLAIMED','RUNNING'))::int,
    count(*) filter (where status='QUEUED')::int,
    count(*) filter (where status='NEEDS_REVIEW')::int
  into v_total,v_success,v_failed,v_running,v_queued,v_review
  from public.automation_items where batch_id=p_batch_id;
  select status into v_status from public.automation_batches
  where id=p_batch_id for update;
  if not found then return; end if;
  if v_total>0 then
    if v_running>0 then v_status:='RUNNING';
    elsif v_queued>0 then v_status:='QUEUED';
    elsif v_review>0 then v_status:='NEEDS_REVIEW';
    elsif v_failed=v_total then v_status:='FAILED';
    elsif v_success=v_total then v_status:='SUCCEEDED';
    elsif v_success+v_failed=v_total then v_status:='PARTIAL_SUCCESS';
    end if;
  end if;
  update public.automation_batches
  set total_count=v_total,success_count=v_success,failed_count=v_failed,
    status=v_status,updated_at=clock_timestamp() where id=p_batch_id;
end;
$$;
revoke all on function private.sync_batch_status_and_counts(uuid)
  from public, anon, authenticated, service_role;

alter function public.merge_automation_batches(uuid,uuid,text) set schema private;
alter function private.merge_automation_batches(uuid,uuid,text)
  rename to merge_automation_batches_before_owner_guard;
revoke all on function private.merge_automation_batches_before_owner_guard(uuid,uuid,text)
  from public, anon, authenticated, service_role;

alter function public.merge_customers_into_batch(uuid[],uuid,text) set schema private;
alter function private.merge_customers_into_batch(uuid[],uuid,text)
  rename to merge_customers_into_batch_before_owner_guard;
revoke all on function private.merge_customers_into_batch_before_owner_guard(uuid[],uuid,text)
  from public, anon, authenticated, service_role;

alter function public.split_customers_from_batch(uuid,uuid[],text,text) set schema private;
alter function private.split_customers_from_batch(uuid,uuid[],text,text)
  rename to split_customers_from_batch_before_owner_guard;
revoke all on function private.split_customers_from_batch_before_owner_guard(uuid,uuid[],text,text)
  from public, anon, authenticated, service_role;

alter function public.update_automation_batch_note(uuid,text) set schema private;
alter function private.update_automation_batch_note(uuid,text)
  rename to update_automation_batch_note_before_owner_guard;
revoke all on function private.update_automation_batch_note_before_owner_guard(uuid,text)
  from public, anon, authenticated, service_role;

create function public.merge_automation_batches(
  p_source_batch_id uuid,p_target_batch_id uuid,p_actor text default 'operator'
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_source_batch_id is null or p_target_batch_id is null
     or p_source_batch_id=p_target_batch_id then
    raise exception 'distinct source and target batches required';
  end if;
  perform private.assert_batch_mutation_access(
    array[p_source_batch_id,p_target_batch_id]);
  if (select task_type from public.automation_batches where id=p_source_batch_id)
     is distinct from
     (select task_type from public.automation_batches where id=p_target_batch_id) then
    raise exception 'cannot merge batches of different task types';
  end if;
  return private.merge_automation_batches_before_owner_guard(
    p_source_batch_id,p_target_batch_id,p_actor);
end;
$$;

create function public.merge_customers_into_batch(
  p_customer_ids uuid[],p_target_batch_id uuid,p_actor text default 'operator'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_batch_ids uuid[];
  v_is_owner boolean;
begin
  if p_customer_ids is null or cardinality(p_customer_ids)=0
     or array_position(p_customer_ids,null) is not null
     or p_target_batch_id is null then
    raise exception 'valid customer ids and target batch required';
  end if;
  -- FK inserts for any selected customer wait on these row locks.
  perform 1 from public.customers c
  where c.id=any(p_customer_ids) order by c.id for update;
  select array_agg(distinct b.id) into v_batch_ids
  from public.automation_batches b
  where b.id=p_target_batch_id or (
    b.task_type='MDAC_REGISTRATION' and exists (
      select 1 from public.automation_items i
      where i.batch_id=b.id and i.customer_id=any(p_customer_ids)));
  v_is_owner := private.assert_batch_mutation_access(v_batch_ids);
  if (select task_type from public.automation_batches where id=p_target_batch_id)
      is distinct from 'MDAC_REGISTRATION'::public.automation_task_type then
    raise exception 'target batch must be MDAC_REGISTRATION';
  end if;
  if exists (
    select 1 from unnest(p_customer_ids) as selected(customer_id)
    left join public.customers c on c.id=selected.customer_id
    where c.id is null or c.deleted_at is not null
      or (not v_is_owner and c.created_by is distinct from auth.uid())
  ) then
    raise exception 'customer owner or Owner required' using errcode='42501';
  end if;
  return private.merge_customers_into_batch_before_owner_guard(
    p_customer_ids,p_target_batch_id,p_actor);
end;
$$;

create function public.split_customers_from_batch(
  p_source_batch_id uuid,p_customer_ids uuid[],
  p_new_batch_name text default '1',p_actor text default 'operator'
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.assert_batch_mutation_access(array[p_source_batch_id]);
  if p_customer_ids is null or cardinality(p_customer_ids)=0
     or array_position(p_customer_ids,null) is not null
     or not exists (
       select 1 from public.automation_items i
       where i.batch_id=p_source_batch_id and i.customer_id=any(p_customer_ids)
     ) then
    raise exception 'selected customers are not in the source batch';
  end if;
  return private.split_customers_from_batch_before_owner_guard(
    p_source_batch_id,p_customer_ids,p_new_batch_name,p_actor);
end;
$$;

create function public.update_automation_batch_note(p_batch_id uuid,p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.assert_batch_mutation_access(array[p_batch_id]);
  return private.update_automation_batch_note_before_owner_guard(p_batch_id,p_note);
end;
$$;

revoke all on function public.merge_automation_batches(uuid,uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function public.merge_customers_into_batch(uuid[],uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function public.split_customers_from_batch(uuid,uuid[],text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.update_automation_batch_note(uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.merge_automation_batches(uuid,uuid,text)
  to authenticated,service_role;
grant execute on function public.merge_customers_into_batch(uuid[],uuid,text)
  to authenticated,service_role;
grant execute on function public.split_customers_from_batch(uuid,uuid[],text,text)
  to authenticated,service_role;
grant execute on function public.update_automation_batch_note(uuid,text)
  to authenticated,service_role;
