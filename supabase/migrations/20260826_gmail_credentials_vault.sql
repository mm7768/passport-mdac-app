-- Secure Gmail credential management.
-- Gmail address is App-managed; App Password is stored in Supabase Vault.
-- Supabase service-role keys remain Railway-only and are never stored here.

alter table public.gmail_settings
  add column if not exists credential_configured boolean not null default false;

comment on column public.gmail_settings.credential_configured is
  'Only indicates whether a Vault-backed Gmail credential exists; never contains the password.';

create table if not exists private.gmail_credentials (
  id boolean primary key default true check (id = true),
  gmail_address text not null default '',
  vault_secret_id uuid not null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger gmail_credentials_set_updated_at
before update on private.gmail_credentials
for each row execute procedure public.set_updated_at();

revoke all on private.gmail_credentials from public, anon, authenticated;

comment on table private.gmail_credentials is
  'Private reference to a Supabase Vault secret. Never expose this table to the App.';

create or replace function public.update_gmail_settings(
  p_gmail_address text
)
returns public.gmail_settings
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_settings public.gmail_settings;
  v_address text := lower(trim(coalesce(p_gmail_address, '')));
  v_current_address text;
  v_configured boolean;
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

  select gmail_address, credential_configured
    into v_current_address, v_configured
    from public.gmail_settings
   where id = true;
  if coalesce(v_configured, false)
     and lower(trim(coalesce(v_current_address, ''))) <> v_address then
    raise exception 'changing Gmail address requires saving the new App Password in the App';
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
      'password_stored', coalesce(v_configured, false)
    )
  );

  return v_settings;
end;
$$;

revoke all on function public.update_gmail_settings(text) from public, anon;
grant execute on function public.update_gmail_settings(text) to authenticated;

create or replace function public.save_gmail_credentials(
  p_gmail_address text,
  p_app_password text
)
returns public.gmail_settings
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_settings public.gmail_settings;
  v_old_secret_id uuid;
  v_secret_id uuid;
  v_address text := lower(trim(coalesce(p_gmail_address, '')));
  v_password text := regexp_replace(coalesce(p_app_password, ''), '[[:space:]]+', '', 'g');
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
  if length(v_password) < 8 or length(v_password) > 128 then
    raise exception 'Gmail App Password length is invalid';
  end if;

  select vault_secret_id
    into v_old_secret_id
    from private.gmail_credentials
   where id = true;

  if v_old_secret_id is null then
    select vault.create_secret(
      v_password,
      'passport-mdac-gmail-app-password',
      'Gmail PIN Worker credential managed by Passport MDAC Desk'
    ) into v_secret_id;
  else
    perform vault.update_secret(
      v_old_secret_id,
      v_password,
      'passport-mdac-gmail-app-password',
      'Gmail PIN Worker credential managed by Passport MDAC Desk'
    );
    v_secret_id := v_old_secret_id;
  end if;

  insert into private.gmail_credentials (
    id, gmail_address, vault_secret_id, updated_by
  ) values (
    true, v_address, v_secret_id, auth.uid()
  )
  on conflict (id) do update set
    gmail_address = excluded.gmail_address,
    vault_secret_id = excluded.vault_secret_id,
    updated_by = auth.uid();

  insert into public.gmail_settings (
    id, gmail_address, credential_configured, updated_by
  ) values (
    true, v_address, true, auth.uid()
  )
  on conflict (id) do update set
    gmail_address = excluded.gmail_address,
    credential_configured = true,
    updated_by = auth.uid();

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    auth.uid(),
    'GMAIL_CREDENTIALS_UPDATED',
    'gmail_settings',
    null,
    jsonb_build_object(
      'gmail_address_present', true,
      'gmail_address_domain', split_part(v_address, '@', 2),
      'password_stored_in_vault', true,
      'password_returned_to_client', false
    )
  );

  select * into v_settings
    from public.gmail_settings
   where id = true;
  return v_settings;
end;
$$;

revoke all on function public.save_gmail_credentials(text, text) from public, anon;
grant execute on function public.save_gmail_credentials(text, text) to authenticated;

create or replace function public.get_gmail_runtime_credentials(
  p_worker_id text
)
returns table (
  gmail_address text,
  gmail_app_password text
)
language plpgsql
security definer
set search_path = public, private, vault
as $$
declare
  v_address text;
  v_password text;
begin
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if not exists (
    select 1
      from public.worker_heartbeats
     where worker_id = trim(p_worker_id)
       and status in ('ONLINE', 'BUSY')
       and last_seen_at > now() - interval '10 minutes'
  ) then
    raise exception 'worker heartbeat is not active';
  end if;

  select c.gmail_address, d.decrypted_secret
    into v_address, v_password
    from private.gmail_credentials c
    join vault.decrypted_secrets d on d.id = c.vault_secret_id
   where c.id = true;
  if v_address is null or v_address = '' or v_password is null or v_password = '' then
    raise exception 'Gmail credentials are not configured';
  end if;

  return query select v_address, v_password;
end;
$$;

revoke all on function public.get_gmail_runtime_credentials(text)
  from public, anon, authenticated;
grant execute on function public.get_gmail_runtime_credentials(text) to service_role;

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
  v_credential_configured boolean;
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items must be a JSON array';
  end if;

  select lower(trim(gmail_address)), credential_configured
    into v_gmail_address, v_credential_configured
    from public.gmail_settings
   where id = true;
  if v_gmail_address is null or v_gmail_address = '' then
    raise exception 'Gmail address must be configured in the App before creating a PIN task';
  end if;
  if not coalesce(v_credential_configured, false) then
    raise exception 'Gmail App Password must be configured in the App before creating a PIN task';
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
