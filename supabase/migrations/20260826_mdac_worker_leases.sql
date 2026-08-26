-- MDAC headless Worker queue hardening.
-- This migration contains no credentials, passport values, or real submission logic.

alter table public.automation_batches
  add column if not exists locked_by text,
  add column if not exists locked_at timestamptz,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists attempt_count integer not null default 0;

alter table public.automation_items
  add column if not exists lease_expires_at timestamptz;

create index if not exists automation_batches_mdac_queue_idx
  on public.automation_batches (task_type, status, created_at)
  where task_type = 'MDAC_REGISTRATION';

create index if not exists automation_batches_lease_idx
  on public.automation_batches (lease_expires_at)
  where lease_expires_at is not null;

create index if not exists automation_items_lease_idx
  on public.automation_items (lease_expires_at)
  where lease_expires_at is not null;

comment on column public.automation_batches.locked_by is
  'Worker lease owner; cleared when the batch is released or completed.';
comment on column public.automation_batches.lease_expires_at is
  'UTC lease expiry used for crash recovery; never implies a successful MDAC submission.';
comment on column public.automation_items.lease_expires_at is
  'UTC item lease expiry used to return abandoned work to the queue.';

create or replace function public.claim_mdac_batch(
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

  select b.*
    into v_batch
    from public.automation_batches b
   where b.task_type = 'MDAC_REGISTRATION'
     and b.attempt_count < p_max_attempts
     and (
       (
         b.status = 'QUEUED'
         and exists (
           select 1
             from public.automation_items i
            where i.batch_id = b.id
              and i.status = 'QUEUED'
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

  -- A crashed worker must not keep CLAIMED/RUNNING items forever. Requeue only
  -- items whose own lease or the parent batch lease has expired.
  update public.automation_items
     set status = 'QUEUED',
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         started_at = null,
         error_code = 'LEASE_EXPIRED',
         error_message = 'Previous MDAC Worker lease expired; item returned to queue',
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
         note = coalesce(note, '') || ' | fill-preview Worker 已领取；禁止 Submit'
   where id = v_batch.id;

  select * into v_batch
    from public.automation_batches
   where id = v_batch.id;

  return next v_batch;
end;
$$;

create or replace function public.claim_mdac_item(
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

  select i.*
    into v_item
    from public.automation_items i
    join public.automation_batches b on b.id = i.batch_id
   where i.batch_id = p_batch_id
     and i.status = 'QUEUED'
     and i.attempt_count < p_max_attempts
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

  select * into v_item
    from public.automation_items
   where id = v_item.id;

  return next v_item;
end;
$$;

create or replace function public.heartbeat_mdac(
  p_worker_id text,
  p_batch_id uuid default null,
  p_item_id uuid default null,
  p_lease_seconds integer default 900,
  p_status public.worker_status default 'ONLINE',
  p_hostname text default 'railway',
  p_version text default 'mdac-fill-preview'
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
    coalesce(nullif(trim(p_version), ''), 'mdac-fill-preview'),
    p_status,
    case when p_status = 'BUSY' then p_batch_id else null end,
    v_now,
    jsonb_build_object('execution_mode', 'FILL_PREVIEW', 'submitted', false)
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
     where id = p_batch_id
       and locked_by = p_worker_id;
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

create or replace function public.finish_mdac_fill_preview(
  p_item_id uuid,
  p_worker_id text,
  p_screenshot_path text default null,
  p_raw_summary jsonb default '{}'::jsonb,
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
  v_batch public.automation_batches;
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'preview_only', true,
      'submitted', false,
      'result_confirmed', false,
      'worker_id', p_worker_id
    );
begin
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;

  update public.automation_items
     set status = 'NEEDS_REVIEW',
         finished_at = now(),
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = p_error_code,
         error_message = p_error_message,
         result_unknown = false
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
  returning * into v_item;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select * into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent MDAC batch not found';
  end if;

  insert into public.mdac_registrations (
    customer_id,
    batch_item_id,
    entry_date,
    exit_date,
    registration_no,
    registration_status,
    raw_summary,
    screenshot_path,
    submitted_at,
    result_confirmed_at
  ) values (
    v_item.customer_id,
    v_item.id,
    v_batch.entry_date,
    v_batch.exit_date,
    null,
    'NEEDS_REVIEW',
    v_summary,
    p_screenshot_path,
    null,
    null
  )
  on conflict (batch_item_id) do update set
    registration_status = 'NEEDS_REVIEW',
    raw_summary = excluded.raw_summary,
    screenshot_path = excluded.screenshot_path,
    submitted_at = null,
    result_confirmed_at = null,
    updated_at = now();

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         status = case
           when not exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
           )
           and exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'NEEDS_REVIEW'
           )
           then 'NEEDS_REVIEW'::public.automation_status
           else b.status
         end,
         note = coalesce(b.note, '') || ' | fill-preview 已完成；等待人工审核，未提交'
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
    'MDAC_FILL_PREVIEW',
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'submitted', false,
      'result_confirmed', false,
      'screenshot_path', p_screenshot_path,
      'error_code', p_error_code
    )
  );

  return v_item;
end;
$$;

revoke execute on function public.claim_mdac_batch(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.claim_mdac_item(uuid, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.heartbeat_mdac(text, uuid, uuid, integer, public.worker_status, text, text) from public, anon, authenticated;
revoke execute on function public.finish_mdac_fill_preview(uuid, text, text, jsonb, text, text) from public, anon, authenticated;

grant execute on function public.claim_mdac_batch(text, integer, integer) to service_role;
grant execute on function public.claim_mdac_item(uuid, text, integer, integer) to service_role;
grant execute on function public.heartbeat_mdac(text, uuid, uuid, integer, public.worker_status, text, text) to service_role;
grant execute on function public.finish_mdac_fill_preview(uuid, text, text, jsonb, text, text) to service_role;
