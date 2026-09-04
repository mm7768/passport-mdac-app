-- Bind human Registration checks to the latest successful MDAC travel dates.
CREATE OR REPLACE FUNCTION public.create_human_query_task(p_customer_id uuid, p_task_type public.automation_task_type, p_settings_snapshot jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_batch public.automation_batches;
  v_item public.automation_items;
  v_customer public.customers;
  v_case_id uuid;
  v_target_entry date;
  v_target_exit date;
  v_snapshot jsonb := coalesce(p_settings_snapshot, '{}'::jsonb);
begin
  if not private.is_active_user() then raise exception 'active user required'; end if;
  if p_task_type not in ('REGISTRATION_CHECK','VISIT_PASS_CHECK') then
    raise exception 'unsupported human query type';
  end if;

  select * into v_customer from public.customers
   where id=p_customer_id and deleted_at is null;
  if not found then raise exception 'customer missing or deleted'; end if;
  if nullif(trim(v_customer.passport_number),'') is null or nullif(trim(v_customer.nationality),'') is null then
    raise exception 'passport number and nationality are required';
  end if;
  if not exists (
    select 1 from public.email_pin_records
     where customer_id=p_customer_id and status='RECEIVED'
       and nullif(trim(pin_value),'') is not null
  ) then raise exception 'customer has no received PIN'; end if;
  if exists (
    select 1 from public.automation_items
     where customer_id=p_customer_id
       and status in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')
  ) then raise exception 'customer already has an active automation item'; end if;

  select id into v_case_id from public.customer_cases
   where customer_id=p_customer_id
   order by created_at desc limit 1;

  if p_task_type='REGISTRATION_CHECK' then
    select r.entry_date, r.exit_date
      into v_target_entry, v_target_exit
      from public.mdac_registrations r
     where r.customer_id=p_customer_id
       and r.registration_status='SUCCEEDED'
     order by coalesce(r.result_confirmed_at,r.submitted_at,r.updated_at) desc
     limit 1;
    if not found then
      raise exception 'no successful MDAC registration exists for this customer';
    end if;
    v_snapshot := v_snapshot || jsonb_build_object(
      'target_entry_date', v_target_entry,
      'target_exit_date', v_target_exit,
      'date_match_required', true
    );
  end if;

  insert into public.automation_batches(
    task_type,created_by,status,total_count,success_count,failed_count,
    note,visit_pass_settings_snapshot
  ) values (
    p_task_type,auth.uid(),'NEEDS_REVIEW',1,0,0,
    case when p_task_type='REGISTRATION_CHECK'
      then '手机端人工完成滑块；只可确认与最近成功 MDAC 入境/离境日期一致的 Registration'
      else '手机端人工完成滑块并判定 Visit Pass；成功必须上传截图' end,
    case when p_task_type='VISIT_PASS_CHECK' then v_snapshot else '{}'::jsonb end
  ) returning * into v_batch;

  insert into public.automation_items(
    batch_id,customer_id,case_id,customer_snapshot,status,started_at,
    error_code,error_message,result_unknown
  ) values (
    v_batch.id,p_customer_id,v_case_id,
    jsonb_build_object(
      'full_name',v_customer.full_name,
      'passport_number',v_customer.passport_number,
      'nationality',v_customer.nationality,
      'target_entry_date',v_target_entry,
      'target_exit_date',v_target_exit,
      'date_match_required',p_task_type='REGISTRATION_CHECK'
    ),
    'NEEDS_REVIEW',now(),'HUMAN_SLIDER_REQUIRED',
    case when p_task_type='REGISTRATION_CHECK'
      then '请完成官方滑块并确认查询结果的入境/离境日期与本次 MDAC 完全一致'
      else '请在手机端完成官方滑块和查询，再选择真实结果' end,
    true
  ) returning * into v_item;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'HUMAN_QUERY_STARTED','automation_items',v_item.id,
    jsonb_build_object(
      'batch_id',v_batch.id,'task_type',p_task_type,'captcha_bypass',false,
      'target_entry_date',v_target_entry,'target_exit_date',v_target_exit
    ));

  return jsonb_build_object(
    'batch_id',v_batch.id,
    'item_id',v_item.id,
    'target_entry_date',v_target_entry,
    'target_exit_date',v_target_exit,
    'date_match_required',p_task_type='REGISTRATION_CHECK'
  );
end;
$function$;

revoke execute on function public.create_human_query_task(uuid,public.automation_task_type,jsonb) from public, anon;
grant execute on function public.create_human_query_task(uuid,public.automation_task_type,jsonb) to authenticated;
