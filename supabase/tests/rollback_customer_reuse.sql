-- Run only after rollback_customer_reuse is applied.
-- Transactional synthetic fixtures: no persistent customers, tasks or files.
begin;
do $test$
declare v_actor uuid;
begin
  select id into v_actor from public.profiles
  where is_active and deleted_at is null limit 1;
  if v_actor is null then raise exception 'test needs an active profile'; end if;
  perform set_config('request.jwt.claim.sub',v_actor::text,true);
end $test$;
set local role authenticated;

do $test$
declare
  v_data jsonb;
  v_id uuid;
  v_new_id uuid;
  v_passport text := 'ZT' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,7));
  v_blocked boolean := false;
begin
  v_data := public.create_customer_with_case(
    'ROLLBACK TEST',v_passport,date '1990-01-01','CHINA','CHN','男',date '2035-01-01'
  );
  v_id := (v_data->'customer'->>'id')::uuid;
  if v_id is null or v_data->'customer'->>'business_status'<>'PENDING' then
    raise exception 'new customer must start pending';
  end if;
  if exists(select 1 from public.passports where customer_id=v_id)
     or exists(select 1 from public.customer_cases where customer_id=v_id) then
    raise exception 'new customer must not create reusable rows';
  end if;
  if has_table_privilege('authenticated','public.customer_cases','INSERT')
     or has_table_privilege('authenticated','public.passports','INSERT') then
    raise exception 'historical tables must not allow client insertion';
  end if;
  begin
    perform public.create_case_for_existing_customer(v_id);
  exception when raise_exception then
    if sqlerrm not like '%复用已停用%' then raise; end if;
    v_blocked := true;
  end;
  if not v_blocked then raise exception 'legacy repeat-order RPC must be blocked'; end if;

  v_blocked := false;
  begin
    perform public.create_customer_with_case(
      'DUPLICATE TEST',v_passport,date '1990-01-01','CHINA','CHN','男',date '2035-01-01'
    );
  exception when unique_violation then v_blocked:=true;
  end;
  if not v_blocked then raise exception 'duplicate active passport accepted'; end if;

  perform set_config('rollback_test.customer_id',v_id::text,true);
  perform set_config('rollback_test.passport',v_passport,true);
end $test$;
reset role;
-- Client DELETE is deliberately restricted: remove only this transaction's
-- synthetic fixture as the test runner. This is not the App hard-delete test.
delete from public.customers
where id=current_setting('rollback_test.customer_id')::uuid
  and full_name='ROLLBACK TEST';
set local role authenticated;
do $test$
declare
  v_id uuid := current_setting('rollback_test.customer_id')::uuid;
  v_passport text := current_setting('rollback_test.passport');
  v_data jsonb;
  v_new_id uuid;
begin
  if exists(select 1 from public.customers where id=v_id) then
    raise exception 'synthetic delete did not remove customer';
  end if;
  v_data := public.create_customer_with_case(
    'RECREATED TEST',v_passport,date '1990-01-01','CHINA','CHN','男',date '2035-01-01'
  );
  v_new_id := (v_data->'customer'->>'id')::uuid;
  if v_new_id is null or v_new_id=v_id then
    raise exception 'recreation must produce a new identity';
  end if;
  if exists(select 1 from public.email_pin_records where customer_id=v_new_id) then
    raise exception 'new workflow inherited an old PIN';
  end if;
end $test$;
reset role;

do $test$
begin
  if exists(
    select 1 from pg_trigger
    where tgname in ('automation_items_sync_case','customers_sync_case_status',
                     'email_pin_records_capture_profile') and tgenabled<>'D'
  ) then raise exception 'case/profile double writing still enabled'; end if;
  if position('date_match_required' in pg_get_functiondef(
    'public.create_human_query_task(uuid,public.automation_task_type,jsonb)'::regprocedure
  ))=0 then raise exception 'Registration date matching was lost'; end if;
end $test$;
rollback;
