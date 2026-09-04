-- Mobile human-review flow for Registration and Visit Pass.
-- A FOUND outcome is impossible to confirm without a private evidence screenshot.
CREATE OR REPLACE FUNCTION public.create_human_query_task(p_customer_id uuid, p_task_type automation_task_type, p_settings_snapshot jsonb DEFAULT '{}'::jsonb)
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

  insert into public.automation_batches(
    task_type,created_by,status,total_count,success_count,failed_count,
    note,visit_pass_settings_snapshot
  ) values (
    p_task_type,auth.uid(),'NEEDS_REVIEW',1,0,0,
    case when p_task_type='REGISTRATION_CHECK'
      then '手机端人工完成滑块并判定 Registration；成功必须上传截图'
      else '手机端人工完成滑块并判定 Visit Pass；成功必须上传截图' end,
    case when p_task_type='VISIT_PASS_CHECK' then coalesce(p_settings_snapshot,'{}'::jsonb) else '{}'::jsonb end
  ) returning * into v_batch;

  insert into public.automation_items(
    batch_id,customer_id,case_id,customer_snapshot,status,started_at,
    error_code,error_message,result_unknown
  ) values (
    v_batch.id,p_customer_id,v_case_id,
    jsonb_build_object(
      'full_name',v_customer.full_name,
      'passport_number',v_customer.passport_number,
      'nationality',v_customer.nationality
    ),
    'NEEDS_REVIEW',now(),'HUMAN_SLIDER_REQUIRED',
    '请在手机端完成官方滑块和查询，再选择真实结果',true
  ) returning * into v_item;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'HUMAN_QUERY_STARTED','automation_items',v_item.id,
    jsonb_build_object('batch_id',v_batch.id,'task_type',p_task_type,'captcha_bypass',false));

  return jsonb_build_object('batch_id',v_batch.id,'item_id',v_item.id);
end;
$function$

CREATE OR REPLACE FUNCTION public.finish_human_query_task(p_item_id uuid, p_outcome text, p_screenshot_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_outcome text := upper(trim(coalesce(p_outcome,'')));
  v_path text := nullif(trim(coalesce(p_screenshot_path,'')),'');
  v_item_status public.automation_item_status;
  v_batch_status public.automation_status;
  v_business public.business_status;
  v_check public.check_status;
  v_error_code text;
  v_error_message text;
  v_normalized text;
begin
  if not private.is_active_user() then raise exception 'active user required'; end if;
  select i.* into v_item
    from public.automation_items i
    join public.automation_batches b on b.id=i.batch_id
   where i.id=p_item_id and b.created_by=auth.uid()
     and b.task_type in ('REGISTRATION_CHECK','VISIT_PASS_CHECK')
     and i.status='NEEDS_REVIEW';
  if not found then raise exception 'human query task not found or not owned'; end if;
  select * into v_batch from public.automation_batches where id=v_item.batch_id;

  if v_outcome not in ('FOUND','NO_RECORD','PIN_INVALID','PAGE_ERROR') then
    raise exception 'unsupported outcome';
  end if;
  if v_outcome in ('FOUND','PAGE_ERROR') and v_path is null then
    raise exception 'evidence screenshot is required';
  end if;
  if v_path is not null and v_path not like ('human-query-evidence/'||auth.uid()::text||'/%') then
    raise exception 'invalid evidence screenshot path';
  end if;

  if v_outcome='FOUND' then
    v_item_status:='SUCCEEDED'; v_batch_status:='SUCCEEDED'; v_check:='PARSED';
    v_business:=case when v_batch.task_type='REGISTRATION_CHECK'
      then 'REGISTRATION_CHECKED'::public.business_status else 'VISIT_PASS_CHECKED'::public.business_status end;
    v_normalized:='FOUND';
  elsif v_outcome='NO_RECORD' then
    v_item_status:='SUCCEEDED'; v_batch_status:='SUCCEEDED'; v_check:='PARSED';
    v_business:='ACTION_REQUIRED'; v_normalized:='NO_RECORD';
    v_error_code:='NO_RECORD'; v_error_message:='用户确认官方页面没有记录';
  elsif v_outcome='PIN_INVALID' then
    v_item_status:='FAILED'; v_batch_status:='FAILED'; v_check:='FAILED';
    v_business:='ACTION_REQUIRED'; v_normalized:='PIN_INVALID';
    v_error_code:='PIN_INVALID'; v_error_message:='用户确认官方页面提示 PIN 错误';
  else
    v_item_status:='NEEDS_REVIEW'; v_batch_status:='NEEDS_REVIEW'; v_check:='NEEDS_REVIEW';
    v_business:='ACTION_REQUIRED'; v_normalized:='PAGE_ERROR';
    v_error_code:='PAGE_ERROR'; v_error_message:='用户确认官方页面异常，已保存诊断截图';
  end if;

  if v_batch.task_type='REGISTRATION_CHECK' then
    insert into public.registration_checks(
      customer_id,case_id,batch_item_id,checked_at,result_status,raw_summary,
      normalized_status,error_message,screenshot_path,challenge_type,submitted,result_confirmed
    ) values (
      v_item.customer_id,v_item.case_id,v_item.id,now(),v_check,
      jsonb_build_object('source','MOBILE_HUMAN_REVIEW','outcome',v_outcome,'captcha_bypass',false,
                         'screenshot_required',v_outcome in ('FOUND','PAGE_ERROR')),
      v_normalized,v_error_message,v_path,'CAPTCHA_SLIDER',true,v_outcome in ('FOUND','NO_RECORD','PIN_INVALID')
    ) on conflict(batch_item_id) do update set
      checked_at=excluded.checked_at,result_status=excluded.result_status,
      raw_summary=excluded.raw_summary,normalized_status=excluded.normalized_status,
      error_message=excluded.error_message,screenshot_path=excluded.screenshot_path,
      challenge_type=excluded.challenge_type,submitted=excluded.submitted,
      result_confirmed=excluded.result_confirmed,updated_at=now();
  else
    insert into public.visit_pass_checks(
      customer_id,case_id,batch_item_id,checked_at,result_status,raw_summary,
      normalized_status,error_message,screenshot_path,challenge_type,submitted,result_confirmed
    ) values (
      v_item.customer_id,v_item.case_id,v_item.id,now(),v_check,
      jsonb_build_object('source','MOBILE_HUMAN_REVIEW','outcome',v_outcome,'captcha_bypass',false,
                         'screenshot_required',v_outcome in ('FOUND','PAGE_ERROR')),
      v_normalized,v_error_message,v_path,'CAPTCHA_SLIDER',true,v_outcome in ('FOUND','NO_RECORD','PIN_INVALID')
    ) on conflict(batch_item_id) do update set
      checked_at=excluded.checked_at,result_status=excluded.result_status,
      raw_summary=excluded.raw_summary,normalized_status=excluded.normalized_status,
      error_message=excluded.error_message,screenshot_path=excluded.screenshot_path,
      challenge_type=excluded.challenge_type,submitted=excluded.submitted,
      result_confirmed=excluded.result_confirmed,updated_at=now();
  end if;

  update public.automation_items set status=v_item_status,finished_at=case when v_item_status='NEEDS_REVIEW' then null else now() end,
    error_code=v_error_code,error_message=v_error_message,result_unknown=(v_item_status='NEEDS_REVIEW'),
    updated_at=now() where id=v_item.id;
  update public.automation_batches set status=v_batch_status,
    success_count=case when v_item_status='SUCCEEDED' then 1 else 0 end,
    failed_count=case when v_item_status='FAILED' then 1 else 0 end,
    updated_at=now() where id=v_batch.id;
  update public.customers set business_status=v_business,updated_at=now() where id=v_item.customer_id;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'HUMAN_QUERY_FINISHED','automation_items',v_item.id,
    jsonb_build_object('batch_id',v_batch.id,'task_type',v_batch.task_type,'outcome',v_outcome,
      'screenshot_path',v_path,'result_confirmed',v_outcome in ('FOUND','NO_RECORD','PIN_INVALID')));

  return jsonb_build_object('batch_id',v_batch.id,'item_id',v_item.id,'outcome',v_outcome,
    'screenshot_path',v_path,'status',v_item_status);
end;
$function$

revoke execute on function public.create_human_query_task(uuid,public.automation_task_type,jsonb) from public, anon;
grant execute on function public.create_human_query_task(uuid,public.automation_task_type,jsonb) to authenticated;
revoke execute on function public.finish_human_query_task(uuid,text,text) from public, anon;
grant execute on function public.finish_human_query_task(uuid,text,text) to authenticated;
