-- Isolated test database only. Synthetic users, Customer, batch, and evidence
-- are rolled back. No Storage object is created or removed by this fixture.
begin;

do $test$
declare
  v_owner uuid := 'f1000000-0000-4000-8000-000000000001';
  v_operator uuid := 'f1000000-0000-4000-8000-000000000002';
  v_customer uuid;
  v_batch uuid;
  v_item uuid;
  v_denied boolean;
  v_result jsonb;
begin
  insert into auth.users (id,email,aud,role)
  values
    (v_owner,'evidence-owner-test@example.invalid','authenticated','authenticated'),
    (v_operator,'evidence-operator-test@example.invalid','authenticated','authenticated');
  update public.profiles set role='OWNER' where id=v_owner;

  insert into public.customers(
    full_name,passport_number,date_of_birth,place_of_birth,nationality,
    gender,passport_expiry_date,created_by
  ) values (
    'EVIDENCE GUARD TEST',
    'P'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
    date '1990-01-01','TEST','TEST','1',date '2035-01-01',v_operator
  ) returning id into v_customer;
  insert into public.automation_batches(task_type,created_by,status)
  values('REGISTRATION_CHECK',v_operator,'NEEDS_REVIEW')
  returning id into v_batch;
  insert into public.automation_items(batch_id,customer_id,status)
  values(v_batch,v_customer,'NEEDS_REVIEW')
  returning id into v_item;
  insert into public.registration_checks(
    customer_id,batch_item_id,result_status,raw_summary
  ) values (v_customer,v_item,'PARSED','{}'::jsonb);

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_operator::text,true);
  v_denied := false;
  begin
    perform public.rollback_customer_evidence(array[v_customer],'PENDING');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied
     or (select count(*) from public.registration_checks
         where customer_id=v_customer) is distinct from 1
     or (select status from public.automation_items
         where id=v_item) is distinct from 'NEEDS_REVIEW' then
    raise exception 'OPERATOR deleted evidence or terminated a task';
  end if;

  v_result := public.rollback_customer_evidence(
    array[v_customer],'VISIT_PASS_CHECKED');
  if (v_result ->> 'success')::boolean is distinct from true
     or (select count(*) from public.registration_checks
         where customer_id=v_customer) is distinct from 1 then
    raise exception 'non-destructive OPERATOR call failed or changed evidence';
  end if;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles'
      and column_name='access_mode'
  ) then
    execute 'update public.profiles set access_mode=''REVIEW_ONLY'',
      access_expires_at=now()+interval ''3 days'' where id=$1'
      using v_owner;
    v_denied := false;
    begin
      perform public.rollback_customer_evidence(array[v_customer],'PENDING');
    exception when sqlstate '42501' then v_denied := true;
    end;
    if not v_denied then
      raise exception 'review-only OWNER was not denied';
    end if;
    execute 'update public.profiles set access_mode=''FULL'',
      access_expires_at=null where id=$1' using v_owner;
  end if;

  update public.profiles set is_active=false where id=v_owner;
  v_denied := false;
  begin
    perform public.rollback_customer_evidence(array[v_customer],'PENDING');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied then
    raise exception 'inactive OWNER was not denied';
  end if;
  update public.profiles set is_active=true where id=v_owner;

  v_result := public.rollback_customer_evidence(array[v_customer],'PENDING');
  if (v_result ->> 'success')::boolean is distinct from true
     or coalesce(
       (v_result ->> 'cleared_registration_checks')::integer,
       (v_result ->> 'cleared_reg')::integer
     ) is distinct from 1
     or (select count(*) from public.registration_checks
         where customer_id=v_customer) is distinct from 0 then
    raise exception 'active OWNER rollback did not complete';
  end if;
end;
$test$;

rollback;
