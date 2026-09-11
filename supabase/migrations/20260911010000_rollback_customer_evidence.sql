-- RPC to automatically roll back customer evidence (Registration Check PDFs, Visit Pass screenshots)
-- and cancel any active automation items when customer status is rolled back
create or replace function public.rollback_customer_evidence(
    p_customer_ids uuid[],
    p_target_status text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_status text := upper(trim(coalesce(p_target_status, '')));
  v_reg_paths text[];
  v_vp_paths text[];
  v_cleared_reg int := 0;
  v_cleared_vp int := 0;
begin
  if auth.role() is distinct from 'service_role' and not private.is_active_user() then
    raise exception 'active user required';
  end if;

  if p_customer_ids is null or array_length(p_customer_ids, 1) = 0 then
    return jsonb_build_object('success', true, 'cleared_reg', 0, 'cleared_vp', 0);
  end if;

  if v_status in ('PENDING', 'MDAC_REGISTERING', 'MDAC_REGISTERED', 'PIN_PENDING', 'PIN_RECEIVED', 'ACTION_REQUIRED') then
    select coalesce(array_agg(screenshot_path) filter (where screenshot_path is not null and length(trim(screenshot_path)) > 0), array[]::text[])
      into v_reg_paths
      from public.registration_checks
     where customer_id = any(p_customer_ids);

    delete from public.registration_checks
     where customer_id = any(p_customer_ids);
    get diagnostics v_cleared_reg = row_count;

    select coalesce(array_agg(screenshot_path) filter (where screenshot_path is not null and length(trim(screenshot_path)) > 0), array[]::text[])
      into v_vp_paths
      from public.visit_pass_checks
     where customer_id = any(p_customer_ids);

    delete from public.visit_pass_checks
     where customer_id = any(p_customer_ids);
    get diagnostics v_cleared_vp = row_count;

    if array_length(v_reg_paths, 1) > 0 then
      delete from storage.objects
       where bucket_id = 'passport-documents'
         and name = any(v_reg_paths);
    end if;

    if array_length(v_vp_paths, 1) > 0 then
      delete from storage.objects
       where bucket_id = 'passport-documents'
         and name = any(v_vp_paths);
    end if;

    update public.automation_items
       set status = 'FAILED',
           error_code = 'ROLLED_BACK_BY_USER',
           error_message = '客户状态已由用户回退为待处理，已终止并清理该项任务',
           finished_at = coalesce(finished_at, clock_timestamp()),
           updated_at = clock_timestamp()
     where customer_id = any(p_customer_ids)
       and status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW');

  elsif v_status in ('REGISTRATION_CHECKED') then
    select coalesce(array_agg(screenshot_path) filter (where screenshot_path is not null and length(trim(screenshot_path)) > 0), array[]::text[])
      into v_vp_paths
      from public.visit_pass_checks
     where customer_id = any(p_customer_ids);

    delete from public.visit_pass_checks
     where customer_id = any(p_customer_ids);
    get diagnostics v_cleared_vp = row_count;

    if array_length(v_vp_paths, 1) > 0 then
      delete from storage.objects
       where bucket_id = 'passport-documents'
         and name = any(v_vp_paths);
    end if;

    update public.automation_items
       set status = 'FAILED',
           error_code = 'ROLLED_BACK_BY_USER',
           error_message = '客户状态已由用户回退为 Registration Checked，已终止并清理 Visit Pass 任务',
           finished_at = coalesce(finished_at, clock_timestamp()),
           updated_at = clock_timestamp()
     where customer_id = any(p_customer_ids)
       and batch_id in (select id from public.automation_batches where task_type = 'VISIT_PASS_CHECK')
       and status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW');
  end if;

  return jsonb_build_object(
    'success', true,
    'target_status', v_status,
    'cleared_registration_checks', v_cleared_reg,
    'cleared_visit_pass_checks', v_cleared_vp
  );
end;
$$;

revoke execute on function public.rollback_customer_evidence(uuid[], text) from public, anon;
grant execute on function public.rollback_customer_evidence(uuid[], text) to authenticated;
grant execute on function public.rollback_customer_evidence(uuid[], text) to service_role;
