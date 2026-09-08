-- Migration: 20260908194500_mdac_queue_v2.sql
-- Description: Upgrade MDAC queue functions (claim_mdac_batch, finish_mdac_fill_preview, finish_mdac_registration_worker)
-- to retain batch lease during processing, prevent 5-attempt starvation, and support both p_registration_number and p_registration_no.

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
     and (
       (
         b.status = 'QUEUED'
         and exists (
           select 1
             from public.automation_items i
            where i.batch_id = b.id
              and i.status = 'QUEUED'
              and i.attempt_count < p_max_attempts
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
         attempt_count = attempt_count + 1
   where id = v_batch.id;

  select * into v_batch
    from public.automation_batches
   where id = v_batch.id;

  return next v_batch;
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
  v_has_more boolean;
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

  select exists (
    select 1 from public.automation_items i
     where i.batch_id = v_item.batch_id
       and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
  ) into v_has_more;

  update public.automation_batches b
     set locked_by = case when v_has_more then b.locked_by else null end,
         locked_at = case when v_has_more then b.locked_at else null end,
         lease_expires_at = case when v_has_more then now() + interval '15 minutes' else null end,
         status = case
           when not v_has_more and exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'NEEDS_REVIEW'
           ) then 'NEEDS_REVIEW'::public.automation_status
           when not v_has_more then 'SUCCEEDED'::public.automation_status
           else b.status
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


create or replace function public.finish_mdac_registration_worker(
  p_item_id uuid,
  p_worker_id text,
  p_status text,
  p_registration_number text default null,
  p_screenshot_path text default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null,
  p_registration_no text default null
)
returns public.automation_items
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_now timestamptz := now();
  v_status text := upper(trim(coalesce(p_status, 'NEEDS_REVIEW')));
  v_item_status public.automation_item_status;
  v_reg_status public.registration_status;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_summary jsonb;
  v_has_more boolean;
  v_reg_number text := coalesce(nullif(trim(p_registration_number), ''), nullif(trim(p_registration_no), ''));
begin
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_status not in ('SUCCEEDED', 'NEEDS_REVIEW', 'FAILED') then
    raise exception 'invalid finish status: %', v_status;
  end if;

  select *
    into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
   for update;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select *
    into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent batch not found';
  end if;

  if v_status = 'SUCCEEDED' then
    v_item_status := 'SUCCEEDED';
    v_reg_status := 'SUCCEEDED';
    v_error_code := null;
    v_error_message := null;
  elsif v_status = 'FAILED' then
    v_item_status := 'FAILED';
    v_reg_status := 'FAILED';
    v_error_code := coalesce(p_error_code, 'MDAC_REGISTRATION_FAILED');
    v_error_message := coalesce(p_error_message, 'MDAC 官方注册失败');
  else
    v_item_status := 'NEEDS_REVIEW';
    v_reg_status := 'PENDING';
    v_error_code := coalesce(p_error_code, 'NEEDS_HUMAN_INTERVENTION');
    v_error_message := coalesce(p_error_message, '需要人工核对/提交');
  end if;

  v_summary := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'auto_worker', true,
      'submitted', (v_status = 'SUCCEEDED'),
      'result_confirmed', (v_status = 'SUCCEEDED'),
      'completed_at', v_now
    );

  update public.automation_items
     set status = v_item_status,
         finished_at = case when v_item_status = 'NEEDS_REVIEW' then null else v_now end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = (v_item_status = 'NEEDS_REVIEW')
   where id = v_item.id
  returning * into v_item;

  insert into public.mdac_registrations (
    customer_id,
    batch_item_id,
    registered_at,
    status,
    registration_number,
    screenshot_path,
    raw_summary,
    challenge_type,
    submitted,
    result_confirmed
  ) values (
    v_item.customer_id,
    v_item.id,
    case when v_status = 'SUCCEEDED' then v_now else null end,
    v_reg_status,
    v_reg_number,
    nullif(trim(p_screenshot_path), ''),
    v_summary,
    'CAPTCHA_SLIDER',
    (v_status = 'SUCCEEDED'),
    (v_status = 'SUCCEEDED')
  )
  on conflict (batch_item_id) do update set
    registered_at = case when v_status = 'SUCCEEDED' then v_now else mdac_registrations.registered_at end,
    status = excluded.status,
    registration_number = coalesce(excluded.registration_number, mdac_registrations.registration_number),
    screenshot_path = coalesce(excluded.screenshot_path, mdac_registrations.screenshot_path),
    raw_summary = excluded.raw_summary,
    challenge_type = excluded.challenge_type,
    submitted = excluded.submitted,
    result_confirmed = excluded.result_confirmed,
    updated_at = v_now;

  if v_status = 'SUCCEEDED' then
    update public.customers
       set business_status = 'MDAC_REGISTERED',
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  elsif v_status = 'FAILED' then
    update public.customers
       set business_status = 'ACTION_REQUIRED',
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  end if;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'MDAC_AUTO_WORKER_SUBMIT',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_batch.id,
      'customer_id', v_item.customer_id,
      'worker_id', p_worker_id,
      'status', v_status,
      'registration_number', v_reg_number
    )
  );

  select exists (
    select 1 from public.automation_items i
     where i.batch_id = v_item.batch_id
       and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
  ) into v_has_more;

  update public.automation_batches b
     set locked_by = case when v_has_more then b.locked_by else null end,
         locked_at = case when v_has_more then b.locked_at else null end,
         lease_expires_at = case when v_has_more then now() + interval '15 minutes' else null end,
         success_count = (
           select count(*) from public.automation_items i
            where i.batch_id = b.id and i.status = 'SUCCEEDED'
         ),
         failed_count = (
           select count(*) from public.automation_items i
            where i.batch_id = b.id and i.status = 'FAILED'
         ),
         status = case
           when not v_has_more then case
             when exists (
               select 1 from public.automation_items i
                where i.batch_id = b.id and i.status = 'FAILED'
             ) then 'FAILED'::public.automation_status
             when exists (
               select 1 from public.automation_items i
                where i.batch_id = b.id and i.status = 'NEEDS_REVIEW'
             ) then 'NEEDS_REVIEW'::public.automation_status
             else 'SUCCEEDED'::public.automation_status
           end
           else b.status
         end
   where b.id = v_item.batch_id
     and b.locked_by = p_worker_id;

  return v_item;
end;
$$;
