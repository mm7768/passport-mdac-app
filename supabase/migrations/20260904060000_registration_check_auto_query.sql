-- Allow the service-role Registration Check worker to persist confirmed query outcomes.
-- The worker still never bypasses CAPTCHA and never performs a registration submission.

do $migration$
declare
  v_sql text;
begin
  v_sql := pg_get_functiondef(
    'public.finish_registration_check_item(uuid,text,public.check_status,text,jsonb,text,text,boolean,boolean,boolean,integer,text,text)'::regprocedure
  );
  v_sql := replace(v_sql, $$      'result_confirmed', false,$$, $$      'result_confirmed', v_confirmed,$$);
  v_sql := replace(v_sql, $$  if v_confirmed then
    raise exception 'current Registration Check worker cannot confirm results';
  end if;

$$, $$$$);
  v_sql := replace(v_sql, $$  if p_check_status = 'PARSED' and not v_confirmed then$$, $$  if p_check_status = 'PARSED' and v_confirmed then
    v_terminal_status := 'SUCCEEDED';
    v_next_business_status := 'REGISTRATION_CHECKED';
    v_error_code := p_error_code;
    v_error_message := p_error_message;
  elsif p_check_status = 'PARSED' and not v_confirmed then$$);
  v_sql := replace(v_sql, $$    false,
    false
  )
  on conflict (batch_item_id) do update set$$, $$    false,
    v_confirmed
  )
  on conflict (batch_item_id) do update set$$);
  v_sql := replace(v_sql, $$    submitted = false,
    result_confirmed = false,$$, $$    submitted = false,
    result_confirmed = v_confirmed,$$);
  v_sql := replace(v_sql, $$           else b.status
         end,$$, $$           else 'SUCCEEDED'::public.automation_status
         end,$$);
  v_sql := replace(v_sql, $$           else ' | Check Registration 结果待确认；未提交'
         end$$, $$           when v_terminal_status = 'SUCCEEDED' then ' | Check Registration 查询完成'
           else ' | Check Registration 结果待确认'
         end$$);
  v_sql := replace(v_sql, $$    'REGISTRATION_CHECK_REVIEW',$$, $$    case when v_confirmed then 'REGISTRATION_CHECK_COMPLETED' else 'REGISTRATION_CHECK_REVIEW' end,$$);
  v_sql := replace(v_sql, $$      'result_confirmed', false,
      'error_code', v_error_code$$, $$      'result_confirmed', v_confirmed,
      'error_code', v_error_code$$);
  execute v_sql;
end
$migration$;

revoke execute on function public.finish_registration_check_item(uuid,text,public.check_status,text,jsonb,text,text,boolean,boolean,boolean,integer,text,text) from public, anon, authenticated;
grant execute on function public.finish_registration_check_item(uuid,text,public.check_status,text,jsonb,text,text,boolean,boolean,boolean,integer,text,text) to service_role;
