-- Copy App-managed MDAC business defaults into each batch at enqueue time.
-- This prevents later settings edits from changing an already queued batch.

alter table public.automation_batches
  add column if not exists mdac_settings_snapshot jsonb not null default '{}'::jsonb;

comment on column public.automation_batches.mdac_settings_snapshot is
  'Point-in-time MDAC business settings copied from public.mdac_settings; no secrets or submit flags.';

create or replace function public.create_mdac_registration_batch(
  p_entry_date date,
  p_exit_date date,
  p_items jsonb,
  p_note text default null
)
returns public.automation_batches
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_batch public.automation_batches;
  v_item jsonb;
  v_customer_id uuid;
  v_item_count integer;
  v_mdac_settings jsonb;
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if p_entry_date is null or p_exit_date is null then
    raise exception 'entry and exit dates are required';
  end if;
  if p_exit_date < p_entry_date then
    raise exception 'exit date cannot be before entry date';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items must be a JSON array';
  end if;

  v_item_count := jsonb_array_length(p_items);
  if v_item_count < 1 or v_item_count > 200 then
    raise exception 'MDAC batch must contain between 1 and 200 items';
  end if;

  select jsonb_build_object(
    'mdac_email', s.mdac_email,
    'mdac_phone', s.mdac_phone,
    'region_code', s.region_code,
    'travel_mode', s.travel_mode,
    'embark_country', s.embark_country,
    'vessel', s.vessel,
    'accommodation_stay', s.accommodation_stay,
    'address1', s.address1,
    'address2', s.address2,
    'state_code', s.state_code,
    'city_code', s.city_code,
    'postcode', s.postcode,
    'pob_mode', s.pob_mode
  )
    into v_mdac_settings
    from public.mdac_settings s
   where s.id = true;

  if v_mdac_settings is null
     or nullif(trim(v_mdac_settings ->> 'mdac_email'), '') is null
     or nullif(trim(v_mdac_settings ->> 'mdac_phone'), '') is null
     or nullif(trim(v_mdac_settings ->> 'embark_country'), '') is null
     or nullif(trim(v_mdac_settings ->> 'vessel'), '') is null
     or nullif(trim(v_mdac_settings ->> 'address1'), '') is null
     or nullif(trim(v_mdac_settings ->> 'state_code'), '') is null
     or nullif(trim(v_mdac_settings ->> 'city_code'), '') is null
     or nullif(trim(v_mdac_settings ->> 'postcode'), '') is null then
    raise exception '请先在 App 的 MDAC 设置中保存完整的业务默认配置';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'each MDAC item must be a JSON object';
    end if;
    v_customer_id := nullif(v_item ->> 'customer_id', '')::uuid;
    if v_customer_id is null or v_item -> 'customer_snapshot' is null then
      raise exception 'each MDAC item requires customer_id and customer_snapshot';
    end if;
    if not exists (
      select 1
        from public.customers c
       where c.id = v_customer_id
         and c.deleted_at is null
    ) then
      raise exception 'customer is missing or deleted: %', v_customer_id;
    end if;
    if exists (
      select 1
        from public.automation_items i
       where i.customer_id = v_customer_id
         and i.status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW')
    ) then
      raise exception 'customer already has an active automation item: %', v_customer_id;
    end if;
  end loop;

  insert into public.automation_batches (
    task_type,
    created_by,
    status,
    total_count,
    success_count,
    failed_count,
    entry_date,
    exit_date,
    mdac_settings_snapshot,
    note
  ) values (
    'MDAC_REGISTRATION',
    auth.uid(),
    'QUEUED',
    v_item_count,
    0,
    0,
    p_entry_date,
    p_exit_date,
    v_mdac_settings,
    coalesce(nullif(trim(p_note), ''), '已保存客户与 MDAC 设置快照，等待 fill-preview Worker；禁止提交')
  ) returning * into v_batch;

  insert into public.automation_items (
    batch_id,
    customer_id,
    customer_snapshot,
    status
  )
  select
    v_batch.id,
    (value ->> 'customer_id')::uuid,
    value -> 'customer_snapshot',
    'QUEUED'
    from jsonb_array_elements(p_items);

  update public.customers c
     set business_status = 'MDAC_REGISTERING',
         updated_by = auth.uid(),
         updated_at = now()
   where c.id in (
     select (value ->> 'customer_id')::uuid
       from jsonb_array_elements(p_items)
   );

  return v_batch;
end;
$$;

revoke execute on function public.create_mdac_registration_batch(date, date, jsonb, text) from public, anon;
grant execute on function public.create_mdac_registration_batch(date, date, jsonb, text) to authenticated;
