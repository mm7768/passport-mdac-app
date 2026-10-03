-- Isolated test database only. All synthetic rows are rolled back.
begin;

do $test$
declare
  v_owner uuid := 'f2000000-0000-4000-8000-000000000001';
  v_alice uuid := 'f2000000-0000-4000-8000-000000000002';
  v_bob uuid := 'f2000000-0000-4000-8000-000000000003';
  v_alice_customer uuid;
  v_bob_customer uuid;
  v_alice_batch uuid;
  v_alice_target uuid;
  v_bob_batch uuid;
  v_mdac_target uuid;
  v_mdac_other uuid;
  v_denied boolean;
  v_result jsonb;
begin
  insert into auth.users(id,email,aud,role) values
    (v_owner,'batch-owner-test@example.invalid','authenticated','authenticated'),
    (v_alice,'batch-alice-test@example.invalid','authenticated','authenticated'),
    (v_bob,'batch-bob-test@example.invalid','authenticated','authenticated');
  update public.profiles set role='OWNER' where id=v_owner;

  insert into public.customers(
    full_name,passport_number,date_of_birth,place_of_birth,nationality,
    gender,passport_expiry_date,created_by
  ) values (
    'ALICE BATCH TEST','A'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
    date '1990-01-01','TEST','TEST','1',date '2035-01-01',v_alice
  ) returning id into v_alice_customer;
  insert into public.customers(
    full_name,passport_number,date_of_birth,place_of_birth,nationality,
    gender,passport_expiry_date,created_by
  ) values (
    'BOB BATCH TEST','B'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
    date '1990-01-01','TEST','TEST','1',date '2035-01-01',v_bob
  ) returning id into v_bob_customer;

  insert into public.automation_batches(task_type,created_by,status)
  values('REGISTRATION_CHECK',v_alice,'SUCCEEDED') returning id into v_alice_batch;
  insert into public.automation_batches(task_type,created_by,status)
  values('REGISTRATION_CHECK',v_alice,'SUCCEEDED') returning id into v_alice_target;
  insert into public.automation_batches(task_type,created_by,status)
  values('REGISTRATION_CHECK',v_bob,'SUCCEEDED') returning id into v_bob_batch;
  insert into public.automation_items(batch_id,customer_id,status)
  values(v_alice_batch,v_alice_customer,'SUCCEEDED');
  insert into public.automation_items(batch_id,customer_id,status)
  values(v_bob_batch,v_bob_customer,'SUCCEEDED');

  insert into public.automation_batches(
    task_type,created_by,status,entry_date,exit_date
  ) values (
    'MDAC_REGISTRATION',v_alice,'SUCCEEDED',date '2030-01-01',date '2030-01-02'
  ) returning id into v_mdac_target;
  insert into public.automation_batches(
    task_type,created_by,status,entry_date,exit_date
  ) values (
    'MDAC_REGISTRATION',v_bob,'SUCCEEDED',date '2030-01-01',date '2030-01-02'
  ) returning id into v_mdac_other;
  insert into public.automation_items(batch_id,customer_id,status)
  values(v_mdac_other,v_bob_customer,'SUCCEEDED');

  if has_function_privilege('anon',
       'public.merge_automation_batches(uuid,uuid,text)','EXECUTE')
     or has_function_privilege('anon',
       'public.merge_customers_into_batch(uuid[],uuid,text)','EXECUTE')
     or has_function_privilege('anon',
       'public.split_customers_from_batch(uuid,uuid[],text,text)','EXECUTE')
     or has_function_privilege('anon',
       'public.update_automation_batch_note(uuid,text)','EXECUTE') then
    raise exception 'anon can execute a batch mutation RPC';
  end if;

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_alice::text,true);

  v_denied := false;
  begin
    perform public.merge_automation_batches(v_bob_batch,v_alice_target,'owner');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied or not exists (
    select 1 from public.automation_items where batch_id=v_bob_batch
  ) then raise exception 'cross-user merge was not denied'; end if;

  v_denied := false;
  begin
    perform public.split_customers_from_batch(
      v_bob_batch,array[v_bob_customer],'1','owner');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied then raise exception 'cross-user split was not denied'; end if;

  v_denied := false;
  begin
    perform public.update_automation_batch_note(v_bob_batch,'changed');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied then raise exception 'cross-user note edit was not denied'; end if;

  v_denied := false;
  begin
    perform public.merge_customers_into_batch(
      array[v_bob_customer],v_mdac_target,'owner');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied or not exists (
    select 1 from public.automation_items where batch_id=v_mdac_other
  ) then raise exception 'cross-user customer merge was not denied'; end if;

  -- The deployed target-first overload must not bypass the canonical guard.
  if to_regprocedure('public.merge_customers_into_batch(uuid,uuid[],text)') is not null then
    if has_function_privilege('anon',
      'public.merge_customers_into_batch(uuid,uuid[],text)','EXECUTE')
      or has_function_privilege('authenticated',
      'private.merge_customers_target_first_before_owner_guard(uuid,uuid[],text)','EXECUTE') then
      raise exception 'target-first overload or legacy body has unsafe ACL';
    end if;
    v_denied := false;
    begin
      perform public.merge_customers_into_batch(v_mdac_target,array[v_bob_customer],'owner');
    exception when sqlstate '42501' then v_denied := true;
    end;
    if not v_denied then raise exception 'target-first cross-user merge accepted'; end if;
  end if;

  -- Own-batch paths remain usable for Operators.
  v_result := public.merge_automation_batches(v_alice_batch,v_alice_target);
  if (v_result->>'success')::boolean is distinct from true or not exists (
    select 1 from public.automation_items
    where batch_id=v_alice_target and customer_id=v_alice_customer
  ) then raise exception 'own-batch merge failed'; end if;
  v_result := public.split_customers_from_batch(
    v_alice_target,array[v_alice_customer]);
  if (v_result->>'split_count')::int is distinct from 1 then
    raise exception 'own-batch split failed';
  end if;
  perform public.update_automation_batch_note(
    (v_result->>'new_batch_id')::uuid,'own note');
  v_result := public.merge_customers_into_batch(
    array[v_alice_customer],v_mdac_target);
  if (v_result->>'moved_count')::int is distinct from 1 then
    raise exception 'own-customer merge failed';
  end if;
  if to_regprocedure('public.merge_customers_into_batch(uuid,uuid[],text)') is not null then
    v_result := public.merge_customers_into_batch(v_mdac_target,array[v_alice_customer]);
    if (v_result->>'success')::boolean is distinct from true then
      raise exception 'target-first own-customer merge failed';
    end if;
  end if;

  -- Website's later profile migration introduces review-only access.
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles'
      and column_name='access_mode'
  ) then
    execute 'update public.profiles set access_mode=''REVIEW_ONLY'',
      access_expires_at=now()+interval ''3 days'' where id=$1' using v_owner;
    perform set_config('request.jwt.claim.sub',v_owner::text,true);
    v_denied := false;
    begin
      perform public.update_automation_batch_note(v_bob_batch,'review edit');
    exception when sqlstate '42501' then v_denied := true;
    end;
    if not v_denied then raise exception 'review-only Owner was not denied'; end if;
    if to_regprocedure('public.merge_customers_into_batch(uuid,uuid[],text)') is not null then
      v_denied := false;
      begin
        perform public.merge_customers_into_batch(v_mdac_target,array[v_alice_customer]);
      exception when sqlstate '42501' then v_denied := true;
      end;
      if not v_denied then raise exception 'target-first review-only Owner accepted'; end if;
    end if;
  end if;
end;
$test$;

rollback;
