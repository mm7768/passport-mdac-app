-- ==============================================================================
-- Combined Migration: Automated Worker RPCs for MDAC, Registration Check, and Visit Pass Check
-- Safe and idempotent: can be executed in Supabase SQL Editor in one go.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. MDAC Registration Auto Worker RPC
-- ------------------------------------------------------------------------------
create or replace function public.finish_mdac_registration_worker(
  p_item_id uuid,
  p_worker_id text,
  p_status text, -- 'SUCCEEDED', 'NEEDS_REVIEW', 'FAILED'
  p_registration_number text default null,
  p_screenshot_path text default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null
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
    nullif(trim(p_registration_number), ''),
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
      'registration_number', p_registration_number
    )
  );

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where b.id = v_item.batch_id
     and not exists (
       select 1
         from public.automation_items i
        where i.batch_id = b.id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
     );

  return v_item;
end;
$$;

revoke execute on function public.finish_mdac_registration_worker(uuid, text, text, text, text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.finish_mdac_registration_worker(uuid, text, text, text, text, jsonb, text, text) to service_role;


-- ------------------------------------------------------------------------------
-- 2. Check Registration Auto Worker RPC
-- ------------------------------------------------------------------------------
create or replace function public.finish_registration_check_worker(
  p_item_id uuid,
  p_worker_id text,
  p_outcome text, -- 'FOUND', 'NO_RECORD', 'PIN_INVALID', 'PAGE_ERROR', 'NEEDS_REVIEW'
  p_evidence_path text default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null
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
  v_outcome text := upper(trim(coalesce(p_outcome, 'NEEDS_REVIEW')));
  v_item_status public.automation_item_status;
  v_check_status public.check_status;
  v_business public.business_status;
  v_normalized text;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_summary jsonb;
begin
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_outcome not in ('FOUND', 'NO_RECORD', 'PIN_INVALID', 'PAGE_ERROR', 'NEEDS_REVIEW') then
    raise exception 'invalid check outcome: %', v_outcome;
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

  if v_outcome = 'FOUND' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'FOUND';
    v_business := 'REGISTRATION_CHECKED';
    v_error_code := null;
    v_error_message := null;
  elsif v_outcome = 'NO_RECORD' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'NO_RECORD';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'NO_RECORD');
    v_error_message := coalesce(p_error_message, '官方页面显示无记录');
  elsif v_outcome = 'PIN_INVALID' then
    v_item_status := 'FAILED';
    v_check_status := 'FAILED';
    v_normalized := 'PIN_INVALID';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'PIN_INVALID');
    v_error_message := coalesce(p_error_message, '官方页面提示 PIN 错误');
  else
    v_item_status := 'NEEDS_REVIEW';
    v_check_status := 'NEEDS_REVIEW';
    v_normalized := coalesce(p_error_code, 'PAGE_ERROR');
    v_business := null;
    v_error_code := coalesce(p_error_code, 'NEEDS_HUMAN_INTERVENTION');
    v_error_message := coalesce(p_error_message, 'Check Registration 需要人工审核');
  end if;

  v_summary := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'auto_worker', true,
      'submitted', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
      'result_confirmed', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
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

  insert into public.registration_checks (
    customer_id,
    case_id,
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
    v_item.case_id,
    v_item.id,
    v_now,
    v_check_status,
    v_summary,
    v_normalized,
    v_error_message,
    nullif(trim(p_evidence_path), ''),
    'CAPTCHA_SLIDER',
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID')
  )
  on conflict (batch_item_id) do update set
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = coalesce(excluded.screenshot_path, registration_checks.screenshot_path),
    challenge_type = excluded.challenge_type,
    submitted = excluded.submitted,
    result_confirmed = excluded.result_confirmed,
    updated_at = v_now;

  if v_business is not null then
    update public.customers
       set business_status = v_business,
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  end if;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'REGISTRATION_CHECK_AUTO_WORKER',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_batch.id,
      'customer_id', v_item.customer_id,
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'status', v_item_status
    )
  );

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where b.id = v_item.batch_id
     and not exists (
       select 1
         from public.automation_items i
        where i.batch_id = b.id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
     );

  return v_item;
end;
$$;

revoke execute on function public.finish_registration_check_worker(uuid, text, text, text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.finish_registration_check_worker(uuid, text, text, text, jsonb, text, text) to service_role;


-- ------------------------------------------------------------------------------
-- 3. Check Visit Pass Auto Worker RPC
-- ------------------------------------------------------------------------------
create or replace function public.finish_visit_pass_check_worker(
  p_item_id uuid,
  p_worker_id text,
  p_outcome text, -- 'FOUND', 'NO_RECORD', 'PIN_INVALID', 'PAGE_ERROR', 'NEEDS_REVIEW'
  p_evidence_path text default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null
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
  v_outcome text := upper(trim(coalesce(p_outcome, 'NEEDS_REVIEW')));
  v_item_status public.automation_item_status;
  v_check_status public.check_status;
  v_business public.business_status;
  v_normalized text;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_summary jsonb;
begin
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_outcome not in ('FOUND', 'NO_RECORD', 'PIN_INVALID', 'PAGE_ERROR', 'NEEDS_REVIEW') then
    raise exception 'invalid check outcome: %', v_outcome;
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

  if v_outcome = 'FOUND' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'FOUND';
    v_business := 'VISIT_PASS_CHECKED';
    v_error_code := null;
    v_error_message := null;
  elsif v_outcome = 'NO_RECORD' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'NO_RECORD';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'NO_RECORD');
    v_error_message := coalesce(p_error_message, '官方页面显示无记录');
  elsif v_outcome = 'PIN_INVALID' then
    v_item_status := 'FAILED';
    v_check_status := 'FAILED';
    v_normalized := 'PIN_INVALID';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'PIN_INVALID');
    v_error_message := coalesce(p_error_message, '官方页面提示 PIN 错误');
  else
    v_item_status := 'NEEDS_REVIEW';
    v_check_status := 'NEEDS_REVIEW';
    v_normalized := coalesce(p_error_code, 'PAGE_ERROR');
    v_business := null;
    v_error_code := coalesce(p_error_code, 'NEEDS_HUMAN_INTERVENTION');
    v_error_message := coalesce(p_error_message, 'Check Visit Pass 需要人工审核');
  end if;

  v_summary := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'auto_worker', true,
      'submitted', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
      'result_confirmed', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
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

  insert into public.visit_pass_checks (
    customer_id,
    case_id,
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
    v_item.case_id,
    v_item.id,
    v_now,
    v_check_status,
    v_summary,
    v_normalized,
    v_error_message,
    nullif(trim(p_evidence_path), ''),
    'CAPTCHA_SLIDER',
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID')
  )
  on conflict (batch_item_id) do update set
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = coalesce(excluded.screenshot_path, visit_pass_checks.screenshot_path),
    challenge_type = excluded.challenge_type,
    submitted = excluded.submitted,
    result_confirmed = excluded.result_confirmed,
    updated_at = v_now;

  if v_business is not null then
    update public.customers
       set business_status = v_business,
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  end if;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'VISIT_PASS_CHECK_AUTO_WORKER',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_batch.id,
      'customer_id', v_item.customer_id,
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'status', v_item_status
    )
  );

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where b.id = v_item.batch_id
     and not exists (
       select 1
         from public.automation_items i
        where i.batch_id = b.id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
     );

  return v_item;
end;
$$;

revoke execute on function public.finish_visit_pass_check_worker(uuid, text, text, text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.finish_visit_pass_check_worker(uuid, text, text, text, jsonb, text, text) to service_role;
