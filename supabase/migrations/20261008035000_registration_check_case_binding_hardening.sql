-- Ensure Registration Check fallback preserves the Order/Case binding.
-- No table/data rewrite; only replaces the existing fallback completion RPC.

CREATE OR REPLACE FUNCTION public.finish_registration_check_item(p_item_id uuid, p_worker_id text, p_check_status check_status, p_normalized_status text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_screenshot_path text DEFAULT NULL::text, p_challenge_type text DEFAULT NULL::text, p_result_confirmed boolean DEFAULT false, p_result_unknown boolean DEFAULT false, p_retryable boolean DEFAULT false, p_max_attempts integer DEFAULT 5, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      'execution_mode', 'REGISTRATION_CHECK',
      'submitted', false,
      'result_confirmed', v_confirmed,
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
  select * into v_item
    from public.automation_items i
   where i.id = p_item_id
     and i.locked_by = p_worker_id
     and i.status in ('CLAIMED', 'RUNNING');
  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  if p_check_status = 'PARSED' and v_confirmed then
    v_terminal_status := 'SUCCEEDED';
    v_next_business_status := 'REGISTRATION_CHECKED';
    v_error_code := p_error_code;
    v_error_message := p_error_message;
  elsif p_check_status = 'PARSED' and not v_confirmed then
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'RESULT_NOT_CONFIRMED');
    v_error_message := coalesce(p_error_message, 'Parsed result requires authorized confirmation');
  elsif p_check_status = 'FAILED' and p_retryable and v_item.attempt_count < p_max_attempts then
    v_terminal_status := 'QUEUED';
    v_next_business_status := null;
    v_error_code := coalesce(p_error_code, 'REGISTRATION_CHECK_RETRY');
    v_error_message := coalesce(p_error_message, 'Registration Check failed transiently; waiting for retry');
  elsif p_check_status = 'FAILED' then
    v_terminal_status := 'FAILED';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'REGISTRATION_CHECK_FAILED');
    v_error_message := coalesce(p_error_message, 'Registration Check failed');
  else
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, case
      when p_challenge_type is not null then 'MANUAL_CHALLENGE_REQUIRED'
      when p_check_status = 'UNPARSED' then 'REGISTRATION_RESULT_UNPARSED'
      else 'REGISTRATION_CHECK_REVIEW'
    end);
    v_error_message := coalesce(p_error_message, 'Registration Check requires manual review');
  end if;

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
    v_confirmed
  )
  on conflict (batch_item_id) do update set
    case_id = excluded.case_id,
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = excluded.screenshot_path,
    challenge_type = excluded.challenge_type,
    submitted = false,
    result_confirmed = v_confirmed,
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
           else 'SUCCEEDED'::public.automation_status
         end,
         note = coalesce(b.note, '') || case
           when v_terminal_status = 'QUEUED' then ' | Check Registration 暂时失败，等待重试'
           when p_challenge_type is not null then ' | 检测到官方 CAPTCHA/滑块，等待人工处理；未提交'
           when v_terminal_status = 'FAILED' then ' | Check Registration 失败，需人工处理'
           when v_terminal_status = 'SUCCEEDED' then ' | Check Registration 查询完成'
           else ' | Check Registration 结果待确认'
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
    case when v_confirmed then 'REGISTRATION_CHECK_COMPLETED' else 'REGISTRATION_CHECK_REVIEW' end,
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'check_status', p_check_status,
      'result_unknown', coalesce(p_result_unknown, false),
      'submitted', false,
      'result_confirmed', v_confirmed,
      'error_code', v_error_code
    )
  );

  select * into v_item from public.automation_items where id = v_item.id;
  return v_item;
end;
$function$
;
