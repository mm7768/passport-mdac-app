-- Check Visit Pass is implemented from the official public page contract.
-- This migration deliberately has no form submission or CAPTCHA-solving path.
-- PIN values are returned only through a service-role-only runtime RPC.

alter table public.automation_batches
  add column if not exists visit_pass_settings_snapshot jsonb not null default '{}'::jsonb;

alter table public.visit_pass_checks
  add column if not exists screenshot_path text,
  add column if not exists challenge_type text,
  add column if not exists submitted boolean not null default false,
  add column if not exists result_confirmed boolean not null default false;

create index if not exists automation_batches_visit_pass_check_queue_idx
  on public.automation_batches (task_type, status, created_at)
  where task_type = 'VISIT_PASS_CHECK';

create index if not exists visit_pass_checks_status_idx
  on public.visit_pass_checks (result_status, updated_at desc);

comment on column public.automation_batches.visit_pass_settings_snapshot is
  'Non-secret Check Visit Pass query settings captured when the batch is queued: email, country/region code and mobile. Never contains Gmail passwords or PIN values.';
comment on column public.visit_pass_checks.screenshot_path is
  'Private Storage path for a minimal Check Visit Pass review screenshot; never a public URL.';
comment on column public.visit_pass_checks.challenge_type is
  'Detected official challenge type such as CAPTCHA_SLIDER; null when no challenge was observed.';
comment on column public.visit_pass_checks.submitted is
  'Always false in the current Check Visit Pass worker; retained as an explicit safety field.';
comment on column public.visit_pass_checks.result_confirmed is
  'True only after a future authorized result-confirmation flow; current worker always writes false.';

create or replace function public.create_visit_pass_check_batch(
  p_items jsonb,
  p_settings_snapshot jsonb,
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
  v_snapshot jsonb;
  v_settings jsonb := coalesce(p_settings_snapshot, '{}'::jsonb);
  v_email text := lower(trim(coalesce(p_settings_snapshot ->> 'email', '')));
  v_reg_cd text := trim(coalesce(p_settings_snapshot ->> 'region_code', ''));
  v_mobile text := trim(coalesce(p_settings_snapshot ->> 'mobile', ''));
  v_item_count integer;
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items must be a JSON array';
  end if;
  if p_settings_snapshot is null or jsonb_typeof(p_settings_snapshot) <> 'object' then
    raise exception 'settings_snapshot must be a JSON object';
  end if;
  if v_email = '' or length(v_email) > 254 or v_email !~* '^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$' then
    raise exception 'valid email is required for Check Visit Pass';
  end if;
  if v_reg_cd = '' or length(v_reg_cd) > 6 or v_reg_cd !~ '^[0-9]+$' then
    raise exception 'valid country/region code is required for Check Visit Pass';
  end if;
  if v_mobile = '' or length(v_mobile) > 12 or v_mobile !~ '^[0-9+\-]+$' then
    raise exception 'valid mobile number is required for Check Visit Pass';
  end if;

  v_item_count := jsonb_array_length(p_items);
  if v_item_count < 1 or v_item_count > 200 then
    raise exception 'Visit Pass Check batch must contain between 1 and 200 items';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'each Visit Pass Check item must be a JSON object';
    end if;

    v_customer_id := nullif(v_item ->> 'customer_id', '')::uuid;
    v_snapshot := v_item -> 'customer_snapshot';
    if v_customer_id is null or v_snapshot is null or jsonb_typeof(v_snapshot) <> 'object' then
      raise exception 'each Visit Pass Check item requires customer_id and customer_snapshot';
    end if;
    if nullif(trim(v_snapshot ->> 'passport_number'), '') is null then
      raise exception 'each Visit Pass Check item requires passport_number';
    end if;
    if nullif(trim(v_snapshot ->> 'nationality'), '') is null then
      raise exception 'each Visit Pass Check item requires nationality';
    end if;
    if not exists (
      select 1
        from public.customers c
       where c.id = v_customer_id
         and c.deleted_at is null
    ) then
      raise exception 'customer is missing or deleted: %', v_customer_id;
    end if;
    if not exists (
      select 1
        from public.email_pin_records p
       where p.customer_id = v_customer_id
         and p.status = 'RECEIVED'
         and nullif(trim(p.pin_value), '') is not null
    ) then
      raise exception 'customer has no received PIN: %', v_customer_id;
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
    visit_pass_settings_snapshot,
    note
  ) values (
    'VISIT_PASS_CHECK',
    auth.uid(),
    'QUEUED',
    v_item_count,
    0,
    0,
    jsonb_build_object(
      'email', v_email,
      'region_code', v_reg_cd,
      'mobile', v_mobile
    ),
    coalesce(nullif(trim(p_note), ''), '已保存 Check Visit Pass 查询快照，等待查询 Worker；不保存 PIN 到快照')
  ) returning * into v_batch;

  -- Deliberately copy only the fields needed to identify the official query.
  -- Do not copy PIN values into automation_items.customer_snapshot.
  insert into public.automation_items (
    batch_id,
    customer_id,
    customer_snapshot,
    status
  )
  select
    v_batch.id,
    (value ->> 'customer_id')::uuid,
    jsonb_build_object(
      'full_name', coalesce(value -> 'customer_snapshot' ->> 'full_name', ''),
      'passport_number', trim(value -> 'customer_snapshot' ->> 'passport_number'),
      'nationality', upper(trim(value -> 'customer_snapshot' ->> 'nationality'))
    ),
    'QUEUED'
    from jsonb_array_elements(p_items);

  return v_batch;
end;
$$;

create or replace function public.claim_visit_pass_check_batch(
  p_worker_id text,
  p_lease_seconds integer default 900,
  p_max_attempts integer default 5
)
returns setof public.automation_batches
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.automation_batches;
  v_now timestamptz := now();
begin
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if p_lease_seconds < 60 or p_lease_seconds > 3600 then
    raise exception 'lease_seconds must be between 60 and 3600';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;

  select b.* into v_batch
    from public.automation_batches b
   where b.task_type = 'VISIT_PASS_CHECK'
     and b.attempt_count < p_max_attempts
     and (
       (
         b.status = 'QUEUED'
         and exists (
           select 1 from public.automation_items i
            where i.batch_id = b.id and i.status = 'QUEUED'
         )
       )
       or (
         b.status in ('CLAIMED', 'RUNNING')
         and b.lease_expires_at is not null
         and b.lease_expires_at < v_now
       )
     )
   order by b.created_at asc, b.id asc
   for update skip locked
   limit 1;

  if not found then
    return;
  end if;

  update public.automation_items
     set status = 'QUEUED',
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         started_at = null,
         error_code = 'LEASE_EXPIRED',
         error_message = 'Previous Visit Pass Check Worker lease expired; item returned to queue',
         result_unknown = false
   where batch_id = v_batch.id
     and status in ('CLAIMED', 'RUNNING')
     and (
       (lease_expires_at is not null and lease_expires_at < v_now)
       or (v_batch.lease_expires_at is not null and v_batch.lease_expires_at < v_now)
     );

  update public.automation_batches
     set status = 'CLAIMED',
         locked_by = p_worker_id,
         locked_at = v_now,
         lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
         attempt_count = attempt_count + 1,
         note = coalesce(note, '') || ' | Visit Pass Check Worker 已领取；不自动处理 CAPTCHA、不提交'
   where id = v_batch.id;

  select * into v_batch from public.automation_batches where id = v_batch.id;
  return next v_batch;
end;
$$;

create or replace function public.claim_visit_pass_check_item(
  p_batch_id uuid,
  p_worker_id text,
  p_lease_seconds integer default 900,
  p_max_attempts integer default 5
)
returns setof public.automation_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.automation_items;
  v_now timestamptz := now();
begin
  if p_batch_id is null then
    raise exception 'batch_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if p_lease_seconds < 60 or p_lease_seconds > 3600 then
    raise exception 'lease_seconds must be between 60 and 3600';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;

  select i.* into v_item
    from public.automation_items i
    join public.automation_batches b on b.id = i.batch_id
   where i.batch_id = p_batch_id
     and i.status = 'QUEUED'
     and i.attempt_count < p_max_attempts
     and b.task_type = 'VISIT_PASS_CHECK'
     and b.locked_by = p_worker_id
     and b.lease_expires_at is not null
     and b.lease_expires_at > v_now
   order by i.created_at asc, i.id asc
   for update of i skip locked
   limit 1;

  if not found then
    return;
  end if;

  update public.automation_items
     set status = 'RUNNING',
         locked_by = p_worker_id,
         locked_at = v_now,
         lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
         attempt_count = attempt_count + 1,
         started_at = coalesce(started_at, v_now),
         error_code = null,
         error_message = null,
         result_unknown = false
   where id = v_item.id;

  select * into v_item from public.automation_items where id = v_item.id;
  return next v_item;
end;
$$;

create or replace function public.get_visit_pass_check_runtime_input(
  p_item_id uuid,
  p_worker_id text
)
returns table (
  passport_number text,
  nationality text,
  email text,
  region_code text,
  mobile text,
  pin_value text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_item_id is null or p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'item_id and worker_id are required';
  end if;

  return query
  select
    trim(i.customer_snapshot ->> 'passport_number'),
    upper(trim(i.customer_snapshot ->> 'nationality')),
    lower(trim(b.visit_pass_settings_snapshot ->> 'email')),
    trim(b.visit_pass_settings_snapshot ->> 'region_code'),
    trim(b.visit_pass_settings_snapshot ->> 'mobile'),
    pin.pin_value
    from public.automation_items i
    join public.automation_batches b on b.id = i.batch_id
    join lateral (
      select p.pin_value
        from public.email_pin_records p
       where p.customer_id = i.customer_id
         and p.status = 'RECEIVED'
         and nullif(trim(p.pin_value), '') is not null
       order by p.received_at desc nulls last, p.created_at desc
       limit 1
    ) pin on true
   where i.id = p_item_id
     and i.locked_by = p_worker_id
     and i.status in ('CLAIMED', 'RUNNING')
     and b.task_type = 'VISIT_PASS_CHECK'
     and b.locked_by = p_worker_id
     and b.lease_expires_at > now();

  if not found then
    raise exception 'runtime input unavailable for item or worker lease';
  end if;
end;
$$;

create or replace function public.heartbeat_visit_pass_check(
  p_worker_id text,
  p_batch_id uuid default null,
  p_item_id uuid default null,
  p_lease_seconds integer default 900,
  p_status public.worker_status default 'ONLINE',
  p_hostname text default 'railway',
  p_version text default 'visit-pass-check-1'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
begin
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if p_lease_seconds < 60 or p_lease_seconds > 3600 then
    raise exception 'lease_seconds must be between 60 and 3600';
  end if;

  insert into public.worker_heartbeats (
    worker_id, hostname, version, status, current_batch_id, last_seen_at, metadata
  ) values (
    p_worker_id,
    coalesce(nullif(trim(p_hostname), ''), 'railway'),
    coalesce(nullif(trim(p_version), ''), 'visit-pass-check-1'),
    p_status,
    case when p_status = 'BUSY' then p_batch_id else null end,
    v_now,
    jsonb_build_object(
      'execution_mode', 'VISIT_PASS_CHECK',
      'captcha_bypass', false,
      'submitted', false,
      'result_confirmed', false
    )
  )
  on conflict (worker_id) do update set
    hostname = excluded.hostname,
    version = excluded.version,
    status = excluded.status,
    current_batch_id = excluded.current_batch_id,
    last_seen_at = excluded.last_seen_at,
    metadata = excluded.metadata;

  if p_status = 'BUSY' and p_batch_id is not null then
    update public.automation_batches
       set locked_at = v_now,
           lease_expires_at = v_now + make_interval(secs => p_lease_seconds)
     where id = p_batch_id and locked_by = p_worker_id;
  end if;

  if p_status = 'BUSY' and p_item_id is not null then
    update public.automation_items
       set locked_at = v_now,
           lease_expires_at = v_now + make_interval(secs => p_lease_seconds)
     where id = p_item_id
       and locked_by = p_worker_id
       and status in ('CLAIMED', 'RUNNING');
  end if;
end;
$$;

create or replace function public.finish_visit_pass_check_item(
  p_item_id uuid,
  p_worker_id text,
  p_check_status public.check_status,
  p_normalized_status text default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_screenshot_path text default null,
  p_challenge_type text default null,
  p_result_confirmed boolean default false,
  p_result_unknown boolean default false,
  p_retryable boolean default false,
  p_max_attempts integer default 5,
  p_error_code text default null,
  p_error_message text default null
)
returns public.automation_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.automation_items;
  v_terminal_status public.automation_item_status;
  v_next_business_status public.business_status;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_confirmed boolean := coalesce(p_result_confirmed, false);
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'execution_mode', 'VISIT_PASS_CHECK',
      'submitted', false,
      'result_confirmed', false,
      'captcha_bypass', false,
      'challenge_type', p_challenge_type
    );
begin
  if p_item_id is null or p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'item_id and worker_id are required';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;
  if v_confirmed then
    raise exception 'current Visit Pass Check worker cannot confirm results';
  end if;

  select * into v_item
    from public.automation_items i
   where i.id = p_item_id
     and i.locked_by = p_worker_id
     and i.status in ('CLAIMED', 'RUNNING');
  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  if p_check_status = 'PARSED' and not v_confirmed then
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'RESULT_NOT_CONFIRMED');
    v_error_message := coalesce(p_error_message, 'Parsed result requires authorized confirmation');
  elsif p_check_status = 'FAILED' and p_retryable and v_item.attempt_count < p_max_attempts then
    v_terminal_status := 'QUEUED';
    v_next_business_status := null;
    v_error_code := coalesce(p_error_code, 'VISIT_PASS_CHECK_RETRY');
    v_error_message := coalesce(p_error_message, 'Visit Pass Check failed transiently; waiting for retry');
  elsif p_check_status = 'FAILED' then
    v_terminal_status := 'FAILED';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'VISIT_PASS_CHECK_FAILED');
    v_error_message := coalesce(p_error_message, 'Visit Pass Check failed');
  else
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, case
      when p_challenge_type is not null then 'MANUAL_CHALLENGE_REQUIRED'
      when p_check_status = 'UNPARSED' then 'VISIT_PASS_RESULT_UNPARSED'
      else 'VISIT_PASS_CHECK_REVIEW'
    end);
    v_error_message := coalesce(p_error_message, 'Visit Pass Check requires manual review');
  end if;

  insert into public.visit_pass_checks (
    customer_id,
    batch_item_id,
    checked_at,
    result_status,
    raw_summary,
    normalized_status,
    error_message,
    screenshot_path,
    challenge_type,
    submitted,
    result_confirmed
  ) values (
    v_item.customer_id,
    v_item.id,
    case when v_terminal_status = 'QUEUED' then null else now() end,
    case when v_terminal_status = 'FAILED' then 'FAILED'::public.check_status
         when p_check_status = 'PARSED' and v_confirmed then 'PARSED'::public.check_status
         else 'NEEDS_REVIEW'::public.check_status end,
    v_summary,
    nullif(trim(p_normalized_status), ''),
    v_error_message,
    nullif(trim(p_screenshot_path), ''),
    nullif(trim(p_challenge_type), ''),
    false,
    false
  )
  on conflict (batch_item_id) do update set
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = excluded.screenshot_path,
    challenge_type = excluded.challenge_type,
    submitted = false,
    result_confirmed = false,
    updated_at = now();

  update public.automation_items
     set status = v_terminal_status,
         finished_at = case when v_terminal_status = 'QUEUED' then null else now() end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = coalesce(p_result_unknown, false)
   where id = v_item.id;

  if v_next_business_status is not null then
    update public.customers
       set business_status = v_next_business_status,
           updated_at = now()
     where id = v_item.customer_id;
  end if;

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         status = case
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
           ) then 'QUEUED'::public.automation_status
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'NEEDS_REVIEW'
           ) then 'NEEDS_REVIEW'::public.automation_status
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'FAILED'
           ) then 'FAILED'::public.automation_status
           else b.status
         end,
         note = coalesce(b.note, '') || case
           when v_terminal_status = 'QUEUED' then ' | Check Visit Pass 暂时失败，等待重试'
           when p_challenge_type is not null then ' | 检测到官方 CAPTCHA/滑块，等待人工处理；未提交'
           when v_terminal_status = 'FAILED' then ' | Check Visit Pass 失败，需人工处理'
           else ' | Check Visit Pass 结果待确认；未提交'
         end
   where b.id = v_item.batch_id and b.locked_by = p_worker_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'VISIT_PASS_CHECK_REVIEW',
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'check_status', p_check_status,
      'result_unknown', coalesce(p_result_unknown, false),
      'submitted', false,
      'result_confirmed', false,
      'error_code', v_error_code
    )
  );

  select * into v_item from public.automation_items where id = v_item.id;
  return v_item;
end;
$$;

revoke execute on function public.create_visit_pass_check_batch(jsonb, jsonb, text) from public, anon;
grant execute on function public.create_visit_pass_check_batch(jsonb, jsonb, text) to authenticated;

revoke execute on function public.claim_visit_pass_check_batch(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.claim_visit_pass_check_item(uuid, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.get_visit_pass_check_runtime_input(uuid, text) from public, anon, authenticated;
revoke execute on function public.heartbeat_visit_pass_check(text, uuid, uuid, integer, public.worker_status, text, text) from public, anon, authenticated;
revoke execute on function public.finish_visit_pass_check_item(uuid, text, public.check_status, text, jsonb, text, text, boolean, boolean, boolean, integer, text, text) from public, anon, authenticated;

grant execute on function public.claim_visit_pass_check_batch(text, integer, integer) to service_role;
grant execute on function public.claim_visit_pass_check_item(uuid, text, integer, integer) to service_role;
grant execute on function public.get_visit_pass_check_runtime_input(uuid, text) to service_role;
grant execute on function public.heartbeat_visit_pass_check(text, uuid, uuid, integer, public.worker_status, text, text) to service_role;
grant execute on function public.finish_visit_pass_check_item(uuid, text, public.check_status, text, jsonb, text, text, boolean, boolean, boolean, integer, text, text) to service_role;

comment on function public.get_visit_pass_check_runtime_input(uuid, text) is
  'Service-role-only runtime input. PIN is returned only to the owned Worker request and is never copied into a client-readable task snapshot.';
comment on function public.finish_visit_pass_check_item(uuid, text, public.check_status, text, jsonb, text, text, boolean, boolean, boolean, integer, text, text) is
  'Atomic Check Visit Pass review writeback. Current worker cannot confirm results, submit, or solve CAPTCHA.';
