-- Gmail mailbox address is an App-managed business setting.
-- The Gmail App Password and Supabase service-role key remain Railway-only secrets.

create table public.gmail_settings (
  id boolean primary key default true check (id = true),
  gmail_address text not null default '' check (length(gmail_address) <= 160),
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.gmail_settings (id)
values (true)
on conflict (id) do nothing;

create trigger gmail_settings_set_updated_at
before update on public.gmail_settings
for each row execute procedure public.set_updated_at();

alter table public.gmail_settings enable row level security;

grant select on public.gmail_settings to authenticated;
revoke insert, update, delete on public.gmail_settings from public, anon, authenticated;

create policy gmail_settings_select_active
on public.gmail_settings for select to authenticated
using (private.is_active_user());

comment on table public.gmail_settings is
  'App-managed Gmail mailbox address only. Never store Gmail passwords or service keys here.';

comment on column public.gmail_settings.gmail_address is
  'Mailbox address used by the Gmail PIN Worker; the password remains a Railway secret.';

create or replace function public.update_gmail_settings(
  p_gmail_address text
)
returns public.gmail_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.gmail_settings;
  v_address text := lower(trim(coalesce(p_gmail_address, '')));
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if v_address = '' or v_address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'valid Gmail address is required';
  end if;
  if length(v_address) > 160 then
    raise exception 'Gmail address is too long';
  end if;

  insert into public.gmail_settings (id, gmail_address, updated_by)
  values (true, v_address, auth.uid())
  on conflict (id) do update set
    gmail_address = excluded.gmail_address,
    updated_by = auth.uid()
  returning * into v_settings;

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    auth.uid(),
    'GMAIL_SETTINGS_UPDATED',
    'gmail_settings',
    null,
    jsonb_build_object(
      'gmail_address_present', true,
      'gmail_address_domain', split_part(v_address, '@', 2),
      'password_stored', false
    )
  );

  return v_settings;
end;
$$;

revoke all on function public.update_gmail_settings(text) from public, anon;
grant execute on function public.update_gmail_settings(text) to authenticated;

alter table public.automation_batches
  add column if not exists gmail_settings_snapshot jsonb not null default '{}'::jsonb;

comment on column public.automation_batches.gmail_settings_snapshot is
  'Immutable Gmail address snapshot for this batch; never contains the mailbox password.';

create or replace function public.create_gmail_pin_batch(
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
  v_gmail_address text;
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items must be a JSON array';
  end if;

  select lower(trim(gmail_address))
    into v_gmail_address
    from public.gmail_settings
   where id = true;
  if v_gmail_address is null or v_gmail_address = '' then
    raise exception 'Gmail address must be configured in the App before creating a PIN task';
  end if;

  v_item_count := jsonb_array_length(p_items);
  if v_item_count < 1 or v_item_count > 200 then
    raise exception 'Gmail PIN batch must contain between 1 and 200 items';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'each Gmail PIN item must be a JSON object';
    end if;
    v_customer_id := nullif(v_item ->> 'customer_id', '')::uuid;
    if v_customer_id is null or v_item -> 'customer_snapshot' is null then
      raise exception 'each Gmail PIN item requires customer_id and customer_snapshot';
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
    gmail_settings_snapshot,
    note
  ) values (
    'GMAIL_PIN',
    auth.uid(),
    'QUEUED',
    v_item_count,
    0,
    0,
    jsonb_build_object(
      'gmail_address', v_gmail_address,
      'source', 'APP_SETTINGS',
      'password_stored', false
    ),
    coalesce(nullif(trim(p_note), ''), '已保存客户和 Gmail 地址快照，等待 Gmail PIN Worker；PIN 不写入日志')
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
     set business_status = 'PIN_PENDING',
         updated_by = auth.uid(),
         updated_at = now()
   where c.id in (
     select (value ->> 'customer_id')::uuid
       from jsonb_array_elements(p_items)
   );

  return v_batch;
end;
$$;

revoke execute on function public.create_gmail_pin_batch(jsonb, text) from public, anon;
grant execute on function public.create_gmail_pin_batch(jsonb, text) to authenticated;
