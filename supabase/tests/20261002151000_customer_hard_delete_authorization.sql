-- Isolated staging only. Run as postgres after the App guard migration.
-- No real Customer IDs are read or deleted. The transaction rolls back.
begin;
do $fixtures$
declare v_owner uuid := gen_random_uuid(); v_operator uuid := gen_random_uuid();
  v_review uuid := gen_random_uuid(); v_empty uuid; v_with_order uuid; v_passport uuid;
begin
  insert into auth.users(id,email,raw_user_meta_data) values
    (v_owner,'purge-owner-'||v_owner::text||'@example.invalid','{"name":"Purge Test Owner"}'::jsonb),
    (v_operator,'purge-operator-'||v_operator::text||'@example.invalid','{"name":"Purge Test Operator"}'::jsonb),
    (v_review,'purge-review-'||v_review::text||'@example.invalid','{"name":"Purge Test Reviewer"}'::jsonb);
  update public.profiles set role='OWNER',access_mode='FULL' where id=v_owner;
  update public.profiles set role='OPERATOR',access_mode='FULL' where id=v_operator;
  update public.profiles set role='OPERATOR',access_mode='REVIEW_ONLY' where id=v_review;
  insert into public.customers(full_name,passport_number,date_of_birth,place_of_birth,
    nationality,gender,passport_expiry_date,created_by)
  values('PURGE EMPTY TEST','P'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
    date '1990-01-01','TEST','TEST','1',date '2035-01-01',v_owner)
  returning id into v_empty;
  insert into public.customers(full_name,passport_number,date_of_birth,place_of_birth,
    nationality,gender,passport_expiry_date,created_by)
  values('PURGE ORDER TEST','P'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
    date '1990-01-01','TEST','TEST','1',date '2035-01-01',v_owner)
  returning id into v_with_order;
  insert into public.passports(customer_id,passport_number,passport_expiry_date,created_by)
    select id,passport_number,passport_expiry_date,v_owner from public.customers
    where id=v_with_order returning id into v_passport;
  insert into public.customer_cases(customer_id,passport_id,created_by)
    values(v_with_order,v_passport,v_owner);
  perform set_config('trash_test.owner',v_owner::text,true);
  perform set_config('trash_test.operator',v_operator::text,true);
  perform set_config('trash_test.review',v_review::text,true);
  perform set_config('trash_test.empty',v_empty::text,true);
  perform set_config('trash_test.with_order',v_with_order::text,true);
end $fixtures$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('trash_test.owner'),true);
do $owner$
declare v_empty uuid := current_setting('trash_test.empty')::uuid;
  v_with_order uuid := current_setting('trash_test.with_order')::uuid;
  v_preview jsonb; v_job jsonb;
begin
  v_preview := public.preview_customer_hard_delete(array[v_with_order]);
  if (v_preview #>> '{rows,0,can_delete}')::boolean
     or not ((v_preview #> '{rows,0,blocked_reasons}') ? 'HAS_ORDER') then
    raise exception 'Owner preview did not block historical Order';
  end if;
  v_job := public.create_customer_hard_delete_job(array[v_with_order]);
  if (v_job ->> 'created')::boolean then
    raise exception 'Owner created purge job for Customer with Order';
  end if;
  v_preview := public.preview_customer_hard_delete(array[v_empty]);
  if not (v_preview #>> '{rows,0,can_delete}')::boolean then
    raise exception 'No-Order Customer should be eligible';
  end if;
  v_job := public.create_customer_hard_delete_job(array[v_empty]);
  if not (v_job ->> 'created')::boolean then
    raise exception 'Owner could not create eligible job';
  end if;
  perform set_config('trash_test.job',(v_job ->> 'job_id'),true);
  -- A failed Storage attempt may be recorded by Owner; the subtransaction
  -- restores the awaiting job so the remaining lifecycle can be tested.
  begin
    if (public.fail_customer_hard_delete((v_job ->> 'job_id')::uuid,'simulated')
        ->> 'status') <> 'FAILED' then
      raise exception 'Owner could not record failed cleanup';
    end if;
    raise exception 'restore test job state' using errcode='ZZ001';
  exception when sqlstate 'ZZ001' then null; end;
end $owner$;

select set_config('request.jwt.claim.sub',current_setting('trash_test.operator'),true);
do $operator$
declare v_customer uuid := current_setting('trash_test.empty')::uuid;
  v_job uuid := current_setting('trash_test.job')::uuid;
  v_owner uuid := current_setting('trash_test.owner')::uuid;
begin
  begin perform public.preview_customer_hard_delete(array[v_customer]);
    raise exception 'Operator preview accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.create_customer_hard_delete_job(array[v_customer]);
    raise exception 'Operator create accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.mark_customer_hard_delete_storage_cleaned(v_job);
    raise exception 'Operator storage confirmation accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.fail_customer_hard_delete(v_job,'test');
    raise exception 'Operator fail accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.complete_customer_hard_delete(v_job);
    raise exception 'Operator complete accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.preview_customer_hard_delete_internal(array[v_customer],v_owner);
    raise exception 'Operator forged Owner ID in private preview' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.create_customer_hard_delete_job_internal(array[v_customer],v_owner);
    raise exception 'Operator forged Owner ID in private create' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.mark_customer_hard_delete_storage_cleaned_internal(v_job,v_owner);
    raise exception 'Operator forged Owner ID in private mark' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.fail_customer_hard_delete_internal(v_job,'forged',v_owner);
    raise exception 'Operator forged Owner ID in private fail' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.complete_customer_hard_delete_internal(v_job,v_owner);
    raise exception 'Operator forged Owner ID in private complete' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
end $operator$;

select set_config('request.jwt.claim.sub',current_setting('trash_test.review'),true);
do $review$
declare v_customer uuid := current_setting('trash_test.empty')::uuid;
  v_job uuid := current_setting('trash_test.job')::uuid;
begin
  begin perform public.preview_customer_hard_delete(array[v_customer]);
    raise exception 'Review preview accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.create_customer_hard_delete_job(array[v_customer]);
    raise exception 'Review create accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.mark_customer_hard_delete_storage_cleaned(v_job);
    raise exception 'Review storage confirmation accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.fail_customer_hard_delete(v_job,'test');
    raise exception 'Review fail accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.complete_customer_hard_delete(v_job);
    raise exception 'Review complete accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.preview_customer_hard_delete_internal(array[v_customer],
    current_setting('trash_test.owner')::uuid);
    raise exception 'Review forged Owner ID in private preview' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
end $review$;

set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $anonymous$
begin
  begin perform public.preview_customer_hard_delete(array[current_setting('trash_test.empty')::uuid]);
    raise exception 'Anonymous preview accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.create_customer_hard_delete_job(array[current_setting('trash_test.empty')::uuid]);
    raise exception 'Anonymous create accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.mark_customer_hard_delete_storage_cleaned(current_setting('trash_test.job')::uuid);
    raise exception 'Anonymous mark accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.fail_customer_hard_delete(current_setting('trash_test.job')::uuid,'test');
    raise exception 'Anonymous fail accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform public.complete_customer_hard_delete(current_setting('trash_test.job')::uuid);
    raise exception 'Anonymous complete accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
  begin perform private.preview_customer_hard_delete_internal(
    array[current_setting('trash_test.empty')::uuid],current_setting('trash_test.owner')::uuid);
    raise exception 'Anonymous private preview accepted' using errcode='ZZ001';
  exception when insufficient_privilege then null; end;
end $anonymous$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('trash_test.owner'),true);
do $complete$
declare v_job uuid := current_setting('trash_test.job')::uuid;
  v_customer uuid := current_setting('trash_test.empty')::uuid;
begin
  if (public.mark_customer_hard_delete_storage_cleaned(v_job) ->> 'status') <> 'STORAGE_CLEANED' then
    raise exception 'Owner could not confirm zero-object Storage cleanup';
  end if;
  if (public.complete_customer_hard_delete(v_job) ->> 'status') <> 'COMPLETED' then
    raise exception 'Owner could not complete eligible purge';
  end if;
  if exists(select 1 from public.customers where id=v_customer) then
    raise exception 'Synthetic no-Order Customer survived completed purge';
  end if;
end $complete$;
reset role;
rollback;
