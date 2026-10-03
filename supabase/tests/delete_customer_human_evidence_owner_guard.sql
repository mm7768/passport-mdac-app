-- Isolated test database only. No evidence or Storage objects are touched.
begin;
do $test$
declare
  v_owner uuid := 'f3000000-0000-4000-8000-000000000001';
  v_operator uuid := 'f3000000-0000-4000-8000-000000000002';
  v_missing_check uuid := 'f3000000-0000-4000-8000-000000000099';
  v_denied boolean;
  v_result jsonb;
begin
  insert into auth.users(id,email,aud,role) values
    (v_owner,'delete-evidence-owner@example.invalid','authenticated','authenticated'),
    (v_operator,'delete-evidence-operator@example.invalid','authenticated','authenticated');
  update public.profiles set role='OWNER' where id=v_owner;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_operator::text,true);
  v_denied := false;
  begin
    perform public.delete_customer_human_evidence(
      v_missing_check,'REGISTRATION_CHECK');
  exception when sqlstate '42501' then v_denied := true;
  end;
  if not v_denied then raise exception 'Operator evidence delete was not denied'; end if;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.delete_customer_human_evidence(
    v_missing_check,'REGISTRATION_CHECK');
  if (v_result->>'success')::boolean is distinct from true then
    raise exception 'Owner evidence delete did not reach existing implementation';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles'
      and column_name='access_mode'
  ) then
    execute 'update public.profiles set access_mode=''REVIEW_ONLY'',
      access_expires_at=now()+interval ''3 days'' where id=$1' using v_owner;
    v_denied := false;
    begin
      perform public.delete_customer_human_evidence(
        v_missing_check,'REGISTRATION_CHECK');
    exception when sqlstate '42501' then v_denied := true;
    end;
    if not v_denied then raise exception 'review-only Owner was not denied'; end if;
  end if;
end;
$test$;
rollback;
