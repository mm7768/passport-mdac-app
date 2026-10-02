-- Run ONLY on an isolated test database after the cancel_automation_batch
-- migration. Synthetic auth rows are rolled back; no batch is deleted.
begin;

do $test$
declare
  v_owner uuid := 'f0000000-0000-4000-8000-000000000001';
  v_operator uuid := 'f0000000-0000-4000-8000-000000000002';
  v_missing_batch uuid := 'f0000000-0000-4000-8000-000000000099';
  v_denied boolean := false;
  v_owner_reached_batch_lookup boolean := false;
begin
  insert into auth.users (id, email, aud, role)
  values
    (v_owner, 'owner-guard-test@example.invalid', 'authenticated', 'authenticated'),
    (v_operator, 'operator-guard-test@example.invalid', 'authenticated', 'authenticated');
  -- The auth.users insert trigger creates active OPERATOR profiles.
  update public.profiles set role = 'OWNER' where id = v_owner;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  begin
    perform public.cancel_automation_batch(v_missing_batch);
  exception when sqlstate '42501' then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'OPERATOR was not denied by cancel_automation_batch';
  end if;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  begin
    perform public.cancel_automation_batch(v_missing_batch);
  exception when others then
    v_owner_reached_batch_lookup := sqlerrm = 'automation batch not found';
  end;
  if not v_owner_reached_batch_lookup then
    raise exception 'active OWNER did not reach batch lookup';
  end if;

  -- This column is introduced by the Website migration later in the chain.
  -- Once present, the forward guard must also exclude review-only Owners.
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'access_mode'
  ) then
    execute 'update public.profiles set access_mode = ''REVIEW_ONLY'',
      access_expires_at = now() + interval ''3 days'' where id = $1'
      using v_owner;
    v_denied := false;
    begin
      perform public.cancel_automation_batch(v_missing_batch);
    exception when sqlstate '42501' then
      v_denied := true;
    end;
    if not v_denied then
      raise exception 'review-only OWNER was not denied';
    end if;
  end if;

  update public.profiles set is_active = false where id = v_owner;
  v_denied := false;
  begin
    perform public.cancel_automation_batch(v_missing_batch);
  exception when sqlstate '42501' then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'inactive OWNER was not denied';
  end if;
end;
$test$;

rollback;
