-- Migration: 20260908190000_gmail_pin_queue_v2.sql
-- Description: Fix Gmail PIN batch queue blockage, add delayed NOT_FOUND retry,
-- retain batch lease for ready items, and enhance customer snapshot with historical anchors.

alter table public.automation_items
  add column if not exists next_attempt_at timestamptz;

comment on column public.automation_items.next_attempt_at is
  'Earliest time a queued item may be claimed again; used by Gmail PIN delayed retries.';

create index if not exists automation_items_gmail_retry_queue_idx
  on public.automation_items (batch_id, next_attempt_at, created_at)
  where status = 'QUEUED';

-- 1. claim_gmail_pin_batch: Batch attempt_count is for observability only.
create or replace function public.claim_gmail_pin_batch(
  p_worker_id text,
  p_lease_seconds integer default 900,
  p_max_attempts integer default 12
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

  select b.*
    into v_batch
    from public.automation_batches b
   where b.task_type = 'GMAIL_PIN'
     and (
       (
         b.status = 'QUEUED'
         and exists (
           select 1
             from public.automation_items i
            where i.batch_id = b.id
              and i.status = 'QUEUED'
              and i.attempt_count < p_max_attempts
              and (i.next_attempt_at is null or i.next_attempt_at <= v_now)
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
         next_attempt_at = null,
         error_code = 'LEASE_EXPIRED',
         error_message = 'Previous Gmail PIN Worker lease expired; item returned to queue',
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
         note = coalesce(note, '') || ' | Gmail PIN Worker 已领取；不记录 PIN 到日志'
   where id = v_batch.id;

  select * into v_batch
    from public.automation_batches
   where id = v_batch.id;

  return next v_batch;
end;
$$;

-- 2. claim_gmail_pin_item: Claim ready item within active batch lease.
create or replace function public.claim_gmail_pin_item(
  p_batch_id uuid,
  p_worker_id text,
  p_lease_seconds integer default 900,
  p_max_attempts integer default 12
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

  select i.*
    into v_item
    from public.automation_items i
    join public.automation_batches b on b.id = i.batch_id
   where i.batch_id = p_batch_id
     and i.status = 'QUEUED'
     and i.attempt_count < p_max_attempts
     and (i.next_attempt_at is null or i.next_attempt_at <= v_now)
     and b.locked_by = p_worker_id
     and b.lease_expires_at is not null
     and b.lease_expires_at > v_now
   order by i.attempt_count asc, i.created_at asc, i.id asc
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
         next_attempt_at = null,
         error_code = null,
         error_message = null,
         result_unknown = false
   where id = v_item.id;

  select * into v_item
    from public.automation_items
   where id = v_item.id;

  return next v_item;
end;
$$;

-- 3. finish_gmail_pin_item: Process item, maintain batch lease for ready items, schedule 5m retry for NOT_FOUND.
create or replace function public.finish_gmail_pin_item(
  p_item_id uuid,
  p_worker_id text,
  p_pin_status public.pin_status,
  p_max_attempts integer default 12,
  p_email_message_id text default null,
  p_sender text default null,
  p_subject text default null,
  p_pin_value text default null,
  p_match_confidence numeric default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_received_at timestamptz default null,
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
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'pin_value_logged', false,
      'email_body_stored', false
    );
  v_terminal_status public.automation_item_status;
  v_next_business_status public.business_status;
  v_next_attempt_at timestamptz;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_has_ready_items boolean;
  v_has_active_items boolean;
  v_has_review_items boolean;
begin
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;
  if p_pin_status = 'RECEIVED' and nullif(trim(coalesce(p_pin_value, '')), '') is null then
    raise exception 'RECEIVED PIN result requires a non-empty pin_value';
  end if;
  if p_pin_status <> 'RECEIVED' and p_pin_value is not null then
    raise exception 'non-RECEIVED PIN result must not contain pin_value';
  end if;

  select * into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING');
  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  -- Verify customer is not deleted.
  if not exists (
    select 1 from public.customers c
     where c.id = v_item.customer_id
       and c.deleted_at is null
  ) then
    -- Mark item failed without reviving or mutating deleted customer.
    update public.automation_items
       set status = 'FAILED',
           finished_at = now(),
           locked_by = null,
           locked_at = null,
           lease_expires_at = null,
           error_code = 'CUSTOMER_DELETED',
           error_message = 'Customer was deleted before task completion'
     where id = v_item.id;
    select * into v_item from public.automation_items where id = v_item.id;
    return v_item;
  end if;

  -- Verify passport consistency if customer snapshot contains passport_number.
  if nullif(trim(v_item.customer_snapshot->>'passport_number'), '') is not null then
    if not exists (
      select 1 from public.customers c
       where c.id = v_item.customer_id
         and regexp_replace(upper(c.passport_number), '[^A-Z0-9]', '', 'g') =
             regexp_replace(upper(v_item.customer_snapshot->>'passport_number'), '[^A-Z0-9]', '', 'g')
    ) then
      update public.automation_items
         set status = 'NEEDS_REVIEW',
             finished_at = now(),
             locked_by = null,
             locked_at = null,
             lease_expires_at = null,
             error_code = 'CUSTOMER_PASSPORT_MODIFIED',
             error_message = 'Customer passport number changed after task was enqueued'
       where id = v_item.id;
      select * into v_item from public.automation_items where id = v_item.id;
      return v_item;
    end if;
  end if;

  if p_pin_status = 'RECEIVED' then
    v_terminal_status := 'SUCCEEDED';
    v_next_business_status := 'PIN_RECEIVED';
  elsif p_pin_status = 'NOT_FOUND' and v_item.attempt_count < p_max_attempts then
    v_terminal_status := 'QUEUED';
    v_next_business_status := null;
    v_next_attempt_at := now() + interval '5 minutes';
    v_error_code := coalesce(p_error_code, 'PIN_NOT_FOUND_RETRY');
    v_error_message := coalesce(p_error_message, 'No matching PIN email found; retry scheduled in 5 minutes');
  else
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(
      p_error_code,
      case
        when p_pin_status = 'PARSE_FAILED' then 'PIN_PARSE_FAILED'
        when p_pin_status = 'NOT_FOUND' then 'PIN_MAX_ATTEMPTS_REACHED'
        else 'PIN_NEEDS_REVIEW'
      end
    );
    v_error_message := coalesce(p_error_message, 'Gmail PIN requires manual review');
  end if;

  insert into public.email_pin_records (
    customer_id,
    batch_item_id,
    email_message_id,
    sender,
    subject,
    matched_by,
    pin_value,
    match_confidence,
    status,
    raw_summary,
    received_at
  ) values (
    v_item.customer_id,
    v_item.id,
    nullif(trim(p_email_message_id), ''),
    nullif(trim(p_sender), ''),
    nullif(trim(p_subject), ''),
    case when p_pin_status = 'RECEIVED' then 'GMAIL_IMAP_PASSPORT' else 'GMAIL_IMAP' end,
    case when p_pin_status = 'RECEIVED' then trim(p_pin_value) else null end,
    p_match_confidence,
    p_pin_status,
    v_summary,
    p_received_at
  )
  on conflict (batch_item_id) do update set
    email_message_id = excluded.email_message_id,
    sender = excluded.sender,
    subject = excluded.subject,
    matched_by = excluded.matched_by,
    pin_value = excluded.pin_value,
    match_confidence = excluded.match_confidence,
    status = excluded.status,
    raw_summary = excluded.raw_summary,
    received_at = excluded.received_at,
    updated_at = now();

  update public.automation_items
     set status = v_terminal_status,
         finished_at = case when v_terminal_status = 'QUEUED' then null else now() end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         next_attempt_at = v_next_attempt_at,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = false
   where id = v_item.id;

  if v_next_business_status is not null then
    update public.customers
       set business_status = v_next_business_status,
           updated_at = now()
     where id = v_item.customer_id;
  end if;

  select
    exists (
      select 1
        from public.automation_items i
       where i.batch_id = v_item.batch_id
         and i.status = 'QUEUED'
         and i.attempt_count < p_max_attempts
         and (i.next_attempt_at is null or i.next_attempt_at <= now())
    ),
    exists (
      select 1
        from public.automation_items i
       where i.batch_id = v_item.batch_id
         and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
    ),
    exists (
      select 1
        from public.automation_items i
       where i.batch_id = v_item.batch_id
         and i.status = 'NEEDS_REVIEW'
    )
    into v_has_ready_items, v_has_active_items, v_has_review_items;

  update public.automation_batches b
     set locked_by = case when v_has_ready_items then b.locked_by else null end,
         locked_at = case when v_has_ready_items then b.locked_at else null end,
         lease_expires_at = case when v_has_ready_items then b.lease_expires_at else null end,
         status = case
           when v_has_ready_items then 'RUNNING'::public.automation_status
           when v_has_active_items then 'QUEUED'::public.automation_status
           when v_has_review_items then 'NEEDS_REVIEW'::public.automation_status
           else 'SUCCEEDED'::public.automation_status
         end,
         note = coalesce(b.note, '') || case
           when p_pin_status = 'RECEIVED' then ' | Gmail PIN 已写回；PIN 不写入日志'
           when v_terminal_status = 'QUEUED' then ' | 暂未找到 PIN，5 分钟后重试'
           else ' | Gmail PIN 需人工审核'
         end
   where b.id = v_item.batch_id
     and b.locked_by = p_worker_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    case
      when p_pin_status = 'RECEIVED' then 'GMAIL_PIN_RECEIVED'
      when v_terminal_status = 'QUEUED' then 'GMAIL_PIN_RETRY_SCHEDULED'
      else 'GMAIL_PIN_REVIEW'
    end,
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'pin_status', p_pin_status,
      'pin_value_logged', false,
      'email_body_stored', false,
      'error_code', v_error_code,
      'retry_scheduled', v_next_attempt_at is not null
    )
  );

  select * into v_item from public.automation_items where id = v_item.id;
  return v_item;
end;
$$;

-- 4. create_gmail_pin_batch: Enrich customer snapshot with historical anchors.
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
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items must be a JSON array';
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
    note
  ) values (
    'GMAIL_PIN',
    auth.uid(),
    'QUEUED',
    v_item_count,
    0,
    0,
    coalesce(nullif(trim(p_note), ''), '已保存客户快照，等待 Gmail PIN Worker；PIN 不写入日志')
  ) returning * into v_batch;

  -- Insert items and enrich customer_snapshot with historical context
  insert into public.automation_items (
    batch_id,
    customer_id,
    customer_snapshot,
    status
  )
  select
    v_batch.id,
    c.id,
    (elem.value -> 'customer_snapshot') || jsonb_build_object(
      'customer_created_at', to_char(c.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'latest_mdac_submitted_at', (
        select to_char(max(m.submitted_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          from public.mdac_registrations m
         where m.customer_id = c.id
      ),
      'previous_pin_value', (
        select e.pin_value
          from public.email_pin_records e
         where e.customer_id = c.id
           and e.status = 'RECEIVED'
         order by e.received_at desc limit 1
      ),
      'previous_pin_received_at', (
        select to_char(e.received_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          from public.email_pin_records e
         where e.customer_id = c.id
           and e.status = 'RECEIVED'
         order by e.received_at desc limit 1
      )
    ),
    'QUEUED'
    from jsonb_array_elements(p_items) elem
    join public.customers c on c.id = (elem.value ->> 'customer_id')::uuid;

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

revoke execute on function public.claim_gmail_pin_batch(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.claim_gmail_pin_item(uuid, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.finish_gmail_pin_item(uuid, text, public.pin_status, integer, text, text, text, text, numeric, jsonb, timestamptz, text, text) from public, anon, authenticated;
revoke execute on function public.create_gmail_pin_batch(jsonb, text) from public, anon;

grant execute on function public.claim_gmail_pin_batch(text, integer, integer) to service_role;
grant execute on function public.claim_gmail_pin_item(uuid, text, integer, integer) to service_role;
grant execute on function public.finish_gmail_pin_item(uuid, text, public.pin_status, integer, text, text, text, text, numeric, jsonb, timestamptz, text, text) to service_role;
grant execute on function public.create_gmail_pin_batch(jsonb, text) to authenticated;
