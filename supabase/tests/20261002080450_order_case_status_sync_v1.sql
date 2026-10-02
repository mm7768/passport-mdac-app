-- Rollback-only integration coverage for exact, monotonic Order status sync.
do $test$
declare
  v_owner uuid;
  v_customer uuid;
  v_case_a uuid;
  v_case_b uuid;
  v_case_a_original public.case_status;
  v_case_b_original public.case_status;
  v_case_a_snapshot jsonb;
  v_worker text := 'order-status-sync-v1-test';
  v_batch uuid;
  v_item uuid;
  v_before_batches bigint;
  v_before_items bigint;
  v_before_mdac bigint;
  v_before_audit bigint;
begin
  select count(*) into v_before_batches from public.automation_batches;
  select count(*) into v_before_items from public.automation_items;
  select count(*) into v_before_mdac from public.mdac_registrations;
  select count(*) into v_before_audit from public.audit_logs;

  begin
    select id into v_owner
    from public.profiles
    where role = 'OWNER'
      and is_active
      and deleted_at is null
      and access_mode = 'FULL'
      and access_expires_at is null
    order by created_at
    limit 1;

    if v_owner is null then
      raise exception 'status sync test requires an active full-access Owner';
    end if;

    select a.customer_id, a.id, b.id, a.case_status, b.case_status,
           a.customer_snapshot
      into v_customer, v_case_a, v_case_b, v_case_a_original,
           v_case_b_original, v_case_a_snapshot
    from public.customer_cases a
    join public.customer_cases b
      on b.customer_id = a.customer_id
     and b.id <> a.id
    where a.business_status is null
      and b.business_status is null
      and not exists (
        select 1 from public.automation_items i
        where i.customer_id = a.customer_id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW')
      )
    order by a.created_at, b.created_at
    limit 1;

    if v_case_a is null or v_case_b is null then
      raise exception 'status sync test requires one Customer with two Orders';
    end if;

    perform set_config('request.jwt.claim.sub', v_owner::text, true);

    update public.customer_cases
       set case_status = 'NEW'
     where id in (v_case_a, v_case_b);

    -- Test A/B/C: the real MDAC finish RPC moves only Order A through
    -- MDAC_PROCESSING -> MDAC_COMPLETED in the same transaction.
    insert into public.automation_batches (
      task_type, created_by, status, total_count, locked_by, locked_at,
      lease_expires_at, entry_date, exit_date
    ) values (
      'MDAC_REGISTRATION', v_owner, 'RUNNING', 1, v_worker,
      clock_timestamp(), clock_timestamp() + interval '5 minutes',
      date '2026-10-10', date '2026-10-13'
    ) returning id into v_batch;

    insert into public.automation_items (
      batch_id, customer_id, case_id, customer_snapshot, status,
      locked_by, locked_at, lease_expires_at, started_at
    ) values (
      v_batch, v_customer, v_case_a, v_case_a_snapshot, 'RUNNING',
      v_worker, clock_timestamp(), clock_timestamp() + interval '5 minutes',
      clock_timestamp()
    ) returning id into v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'MDAC_PROCESSING'
       or (select case_status from public.customer_cases where id = v_case_b)
         <> 'NEW' then
      raise exception 'MDAC running status was not isolated to Order A';
    end if;

    perform public.finish_mdac_registration_worker(
      v_item,
      v_worker,
      'SUCCEEDED',
      'V1-TEST-REG',
      null,
      '{"test":"order-status-sync"}'::jsonb,
      null,
      null,
      null
    );

    if not exists (
      select 1
      from public.automation_items i
      join public.mdac_registrations r on r.batch_item_id = i.id
      join public.customer_cases c on c.id = i.case_id
      where i.id = v_item
        and i.status = 'SUCCEEDED'
        and r.registration_status = 'SUCCEEDED'
        and r.case_id = v_case_a
        and c.case_status = 'MDAC_COMPLETED'
    ) or (select case_status from public.customer_cases where id = v_case_b)
          <> 'NEW' then
      raise exception 'MDAC success did not atomically update the exact Order';
    end if;

    -- Gmail PIN uses the same exact item-to-Order mapping.
    insert into public.automation_batches (
      task_type, created_by, status, total_count
    ) values ('GMAIL_PIN', v_owner, 'RUNNING', 1)
    returning id into v_batch;

    insert into public.automation_items (
      batch_id, customer_id, case_id, customer_snapshot, status
    ) values (
      v_batch, v_customer, v_case_a, v_case_a_snapshot, 'RUNNING'
    ) returning id into v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'WAITING_PIN' then
      raise exception 'Gmail PIN running did not advance to WAITING_PIN';
    end if;

    update public.automation_items
       set status = 'SUCCEEDED', finished_at = clock_timestamp()
     where id = v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'PIN_READY' then
      raise exception 'Gmail PIN success did not advance to PIN_READY';
    end if;

    -- Registration Check review becomes ACTION_REQUIRED and a successful retry
    -- at the same stage is allowed to recover to REGISTRATION_COMPLETED.
    insert into public.automation_batches (
      task_type, created_by, status, total_count
    ) values ('REGISTRATION_CHECK', v_owner, 'RUNNING', 1)
    returning id into v_batch;

    insert into public.automation_items (
      batch_id, customer_id, case_id, customer_snapshot, status
    ) values (
      v_batch, v_customer, v_case_a, v_case_a_snapshot, 'RUNNING'
    ) returning id into v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'WAITING_REGISTRATION' then
      raise exception 'Registration running did not advance to WAITING_REGISTRATION';
    end if;

    update public.automation_items
       set status = 'NEEDS_REVIEW', finished_at = null
     where id = v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'ACTION_REQUIRED' then
      raise exception 'Registration review did not advance to ACTION_REQUIRED';
    end if;

    update public.automation_items
       set status = 'SUCCEEDED', finished_at = clock_timestamp()
     where id = v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'REGISTRATION_COMPLETED' then
      raise exception 'Registration success did not recover to REGISTRATION_COMPLETED';
    end if;

    -- Visit Pass success is the latest successful workflow stage.
    insert into public.automation_batches (
      task_type, created_by, status, total_count
    ) values ('VISIT_PASS_CHECK', v_owner, 'RUNNING', 1)
    returning id into v_batch;

    insert into public.automation_items (
      batch_id, customer_id, case_id, customer_snapshot, status
    ) values (
      v_batch, v_customer, v_case_a, v_case_a_snapshot, 'RUNNING'
    ) returning id into v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'WAITING_VISIT_PASS' then
      raise exception 'Visit Pass running did not advance to WAITING_VISIT_PASS';
    end if;

    update public.automation_items
       set status = 'SUCCEEDED', finished_at = clock_timestamp()
     where id = v_item;

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'VISIT_PASS_COMPLETED' then
      raise exception 'Visit Pass success did not advance to VISIT_PASS_COMPLETED';
    end if;

    -- Test D: a late MDAC success cannot regress the later Visit Pass state.
    insert into public.automation_batches (
      task_type, created_by, status, total_count, entry_date, exit_date
    ) values (
      'MDAC_REGISTRATION', v_owner, 'RUNNING', 1,
      date '2026-10-10', date '2026-10-13'
    )
    returning id into v_batch;

    insert into public.automation_items (
      batch_id, customer_id, case_id, customer_snapshot, status
    ) values (
      v_batch, v_customer, v_case_a, v_case_a_snapshot, 'SUCCEEDED'
    );

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'VISIT_PASS_COMPLETED' then
      raise exception 'late MDAC success regressed a later Order state';
    end if;

    -- Test E: a legacy Item never guesses either Order under this Customer.
    insert into public.automation_batches (
      task_type, created_by, status, total_count
    ) values ('GMAIL_PIN', v_owner, 'SUCCEEDED', 1)
    returning id into v_batch;

    insert into public.automation_items (
      batch_id, customer_id, case_id, customer_snapshot, status
    ) values (
      v_batch, v_customer, null, v_case_a_snapshot, 'SUCCEEDED'
    );

    if (select case_status from public.customer_cases where id = v_case_a)
         <> 'VISIT_PASS_COMPLETED'
       or (select case_status from public.customer_cases where id = v_case_b)
         <> 'NEW' then
      raise exception 'legacy Item guessed or changed an Order';
    end if;

    raise exception 'Order status sync V1 tests passed; rolling back fixtures'
      using errcode = 'ZS001';
  exception when sqlstate 'ZS001' then
    null;
  end;

  if (select case_status from public.customer_cases where id = v_case_a)
       is distinct from v_case_a_original
     or (select case_status from public.customer_cases where id = v_case_b)
       is distinct from v_case_b_original
     or (select count(*) from public.automation_batches) <> v_before_batches
     or (select count(*) from public.automation_items) <> v_before_items
     or (select count(*) from public.mdac_registrations) <> v_before_mdac
     or (select count(*) from public.audit_logs) <> v_before_audit then
    raise exception 'Order status sync V1 rollback guard failed';
  end if;
end
$test$;
