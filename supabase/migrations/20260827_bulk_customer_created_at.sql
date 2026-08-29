-- Allow a tightly controlled, audited OWNER operation to change the system
-- customers.created_at value in bulk. Ordinary authenticated customer updates
-- must not be able to rewrite creation history directly.

create or replace function private.prevent_direct_customer_created_at_change()
returns trigger
language plpgsql
security invoker
set search_path = public, private
as $$
begin
  if new.created_at is distinct from old.created_at
     and current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'customer created_at can only be changed through the owner bulk RPC';
  end if;
  return new;
end;
$$;

drop trigger if exists customers_prevent_created_at_change on public.customers;
create trigger customers_prevent_created_at_change
before update of created_at on public.customers
for each row execute function private.prevent_direct_customer_created_at_change();

comment on function private.prevent_direct_customer_created_at_change() is
  'Blocks direct authenticated rewrites of customers.created_at; the audited owner RPC remains allowed.';

create or replace function public.bulk_update_customer_created_at(
  p_customer_ids uuid[],
  p_created_at timestamptz
)
returns table (
  customer_id uuid,
  old_created_at timestamptz,
  new_created_at timestamptz
)
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_requested_count integer;
  v_active_count integer;
  v_distinct_count integer;
  v_batch_id uuid := gen_random_uuid();
  v_customer record;
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if not private.is_owner() then
    raise exception 'owner required';
  end if;

  v_requested_count := coalesce(cardinality(p_customer_ids), 0);
  if v_requested_count = 0 then
    raise exception 'at least one customer is required';
  end if;
  if v_requested_count > 200 then
    raise exception 'a maximum of 200 customers can be updated at once';
  end if;
  if p_created_at is null then
    raise exception 'created_at is required';
  end if;
  if p_created_at < timestamptz '2000-01-01 00:00:00+00'
     or p_created_at > now() + interval '1 day' then
    raise exception 'created_at must be between 2000-01-01 and one day in the future';
  end if;

  select count(*)::integer, count(distinct requested.id)::integer
    into v_requested_count, v_distinct_count
    from unnest(p_customer_ids) as requested(id);
  if v_requested_count <> v_distinct_count then
    raise exception 'duplicate customer ids are not allowed';
  end if;
  if exists (
    select 1
      from unnest(p_customer_ids) as requested(id)
     where requested.id is null
  ) then
    raise exception 'customer ids cannot contain null';
  end if;

  select count(*)::integer
    into v_active_count
    from public.customers c
   where c.id = any(p_customer_ids)
     and c.deleted_at is null;
  if v_active_count <> v_requested_count then
    raise exception 'one or more selected customers do not exist or are soft-deleted';
  end if;

  for v_customer in
    select c.id, c.created_at
      from public.customers c
     where c.id = any(p_customer_ids)
       and c.deleted_at is null
     order by c.id
     for update
  loop
    update public.customers
       set created_at = p_created_at,
           updated_by = auth.uid()
     where id = v_customer.id;

    insert into public.audit_logs (
      actor_id,
      action,
      entity_type,
      entity_id,
      metadata
    ) values (
      auth.uid(),
      'CUSTOMER_CREATED_AT_BULK_UPDATED',
      'customer',
      v_customer.id,
      jsonb_build_object(
        'batch_id', v_batch_id,
        'batch_size', v_requested_count,
        'old_created_at', v_customer.created_at,
        'new_created_at', p_created_at,
        'direct_system_created_at_change', true
      )
    );

    customer_id := v_customer.id;
    old_created_at := v_customer.created_at;
    new_created_at := p_created_at;
    return next;
  end loop;
end;
$$;

revoke all on function public.bulk_update_customer_created_at(uuid[], timestamptz)
  from public, anon, authenticated;
grant execute on function public.bulk_update_customer_created_at(uuid[], timestamptz)
  to authenticated;

comment on function public.bulk_update_customer_created_at(uuid[], timestamptz) is
  'OWNER-only audited bulk rewrite of active customers.created_at. Does not expose passport data.';
