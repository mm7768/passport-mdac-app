-- Isolated staging only. Run as postgres after the App guard migration.
-- No real Customer IDs are read or deleted. The transaction rolls back.
begin;
-- Test-only helpers disappear with the transaction ROLLBACK. Their explicit
-- failure SQLSTATE lets the negative-control self-test prove they reject {}.
create function private.trash_test_assert_preview(
  p_payload jsonb, p_customer_id uuid, p_row_count integer,
  p_can_delete boolean, p_has_order boolean
) returns void language plpgsql security invoker set search_path = '' as $$
declare v_row jsonb; v_matches integer; v_orders_text text;
begin
  if jsonb_typeof(p_payload) is distinct from 'object'
     or jsonb_typeof(p_payload -> 'rows') is distinct from 'array'
     or jsonb_array_length(p_payload -> 'rows') is distinct from p_row_count then
    raise exception 'preview rows contract changed' using errcode='ZX001';
  end if;
  select count(*) into v_matches from jsonb_array_elements(p_payload -> 'rows') value
    where value ->> 'customer_id' = p_customer_id::text;
  select value into v_row from jsonb_array_elements(p_payload -> 'rows') value
    where value ->> 'customer_id' = p_customer_id::text limit 1;
  if v_matches is distinct from 1
     or jsonb_typeof(v_row -> 'customer_id') is distinct from 'string'
     or jsonb_typeof(v_row -> 'exists') is distinct from 'boolean'
     or (v_row ->> 'exists')::boolean is distinct from true
     or jsonb_typeof(v_row -> 'can_delete') is distinct from 'boolean'
     or (v_row ->> 'can_delete')::boolean is distinct from p_can_delete
     or jsonb_typeof(v_row -> 'blocked_reasons') is distinct from 'array'
     or jsonb_typeof(v_row -> 'record_counts') is distinct from 'object'
     or jsonb_typeof(v_row #> '{record_counts,orders}') is distinct from 'number' then
    raise exception 'preview row contract changed for %',p_customer_id
      using errcode='ZX001';
  end if;
  v_orders_text := v_row #>> '{record_counts,orders}';
  if v_orders_text is null or v_orders_text !~ '^[0-9]+$' then
    raise exception 'preview orders count is not an integer' using errcode='ZX001';
  end if;
  if p_has_order then
    if v_orders_text::bigint <= 0
       or coalesce((v_row -> 'blocked_reasons') ? 'HAS_ORDER',false)
          is distinct from true then
      raise exception 'HAS_ORDER blocker/count missing' using errcode='ZX001';
    end if;
  elsif v_orders_text::bigint is distinct from 0
        or jsonb_array_length(v_row -> 'blocked_reasons') is distinct from 0 then
    raise exception 'No-Order preview has blocker/count' using errcode='ZX001';
  end if;
end $$;

create function private.trash_test_assert_job(
  p_payload jsonb, p_customer_id uuid, p_created boolean
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_job_id uuid; v_matches integer;
begin
  if jsonb_typeof(p_payload) is distinct from 'object'
     or jsonb_typeof(p_payload -> 'created') is distinct from 'boolean'
     or (p_payload ->> 'created')::boolean is distinct from p_created
     or jsonb_typeof(p_payload -> 'blocked') is distinct from 'array' then
    raise exception 'job response contract changed' using errcode='ZX001';
  end if;
  if p_created then
    if nullif(p_payload ->> 'job_id','') is null
       or jsonb_array_length(p_payload -> 'blocked') is distinct from 0 then
      raise exception 'created job ID/blocked contract changed' using errcode='ZX001';
    end if;
    v_job_id := (p_payload ->> 'job_id')::uuid;
    return v_job_id;
  end if;
  select count(*) into v_matches from jsonb_array_elements(p_payload -> 'blocked') value
    where value ->> 'customer_id' = p_customer_id::text
      and jsonb_typeof(value -> 'reasons') = 'array'
      and coalesce((value -> 'reasons') ? 'HAS_ORDER',false);
  if v_matches is distinct from 1 then
    raise exception 'blocked job missing Customer/HAS_ORDER' using errcode='ZX001';
  end if;
  return null;
end $$;

create function private.trash_test_assert_job_status(
  p_payload jsonb, p_job_id uuid, p_status text
) returns void language plpgsql security invoker set search_path = '' as $$
begin
  if jsonb_typeof(p_payload) is distinct from 'object'
     or jsonb_typeof(p_payload -> 'status') is distinct from 'string'
     or (p_payload ->> 'status') is distinct from p_status
     or jsonb_typeof(p_payload -> 'job_id') is distinct from 'string'
     or (p_payload ->> 'job_id') is distinct from p_job_id::text then
    raise exception 'job status/ID response contract changed' using errcode='ZX001';
  end if;
end $$;
grant execute on function private.trash_test_assert_preview(jsonb,uuid,integer,boolean,boolean),
  private.trash_test_assert_job(jsonb,uuid,boolean),
  private.trash_test_assert_job_status(jsonb,uuid,text) to authenticated;

do $negative_control$
declare v_customer uuid := gen_random_uuid(); v_rejected boolean := false;
begin
  begin
    perform private.trash_test_assert_preview('{}'::jsonb,v_customer,1,false,true);
  exception when sqlstate 'ZX001' then v_rejected := true; end;
  if v_rejected is distinct from true then
    raise exception 'negative control: missing rows was accepted';
  end if;
  v_rejected := false;
  begin
    perform private.trash_test_assert_job('{"created":null,"blocked":[]}'::jsonb,
      v_customer,true);
  exception when sqlstate 'ZX001' then v_rejected := true; end;
  if v_rejected is distinct from true then
    raise exception 'negative control: created:null was accepted';
  end if;
end $negative_control$;

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
  v_preview jsonb; v_job jsonb; v_job_id uuid;
begin
  v_preview := public.preview_customer_hard_delete(array[v_with_order]);
  perform private.trash_test_assert_preview(v_preview,v_with_order,1,false,true);
  v_job := public.create_customer_hard_delete_job(array[v_with_order]);
  perform private.trash_test_assert_job(v_job,v_with_order,false);
  v_preview := public.preview_customer_hard_delete(array[v_empty]);
  perform private.trash_test_assert_preview(v_preview,v_empty,1,true,false);
  v_preview := public.preview_customer_hard_delete(array[v_empty,v_with_order]);
  perform private.trash_test_assert_preview(v_preview,v_empty,2,true,false);
  perform private.trash_test_assert_preview(v_preview,v_with_order,2,false,true);
  v_job := public.create_customer_hard_delete_job(array[v_empty]);
  v_job_id := private.trash_test_assert_job(v_job,v_empty,true);
  perform set_config('trash_test.job',v_job_id::text,true);
  -- A failed Storage attempt may be recorded by Owner; the subtransaction
  -- restores the awaiting job so the remaining lifecycle can be tested.
  begin
    perform private.trash_test_assert_job_status(
      public.fail_customer_hard_delete(v_job_id,'simulated'),v_job_id,'FAILED');
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
  v_customer uuid := current_setting('trash_test.empty')::uuid; v_result jsonb;
begin
  v_result := public.mark_customer_hard_delete_storage_cleaned(v_job);
  perform private.trash_test_assert_job_status(v_result,v_job,'STORAGE_CLEANED');
  v_result := public.complete_customer_hard_delete(v_job);
  perform private.trash_test_assert_job_status(v_result,v_job,'COMPLETED');
  if jsonb_typeof(v_result -> 'customer_count') is distinct from 'number'
     or (v_result ->> 'customer_count')::integer is distinct from 1 then
    raise exception 'complete response customer_count changed';
  end if;
  if exists(select 1 from public.customers where id=v_customer) then
    raise exception 'Synthetic no-Order Customer survived completed purge';
  end if;
end $complete$;
reset role;
rollback;
