-- Isolated/local only. Synthetic fixtures; entire transaction rolls back.
begin;
do $fixtures$
declare v_owner uuid:=gen_random_uuid();v_operator uuid:=gen_random_uuid();
  v_review uuid:=gen_random_uuid();v_customer uuid;v_batch uuid;
begin
  insert into auth.users(id,email,raw_user_meta_data) values
    (v_owner,'legacy-read-owner-'||v_owner||'@example.invalid','{"name":"READ OWNER"}'),
    (v_operator,'legacy-read-operator-'||v_operator||'@example.invalid','{"name":"READ OPERATOR"}'),
    (v_review,'legacy-read-review-'||v_review||'@example.invalid','{"name":"READ REVIEW"}');
  update public.profiles set role='OWNER',access_mode='FULL',is_active=true,deleted_at=null,
    must_change_password=false where id=v_owner;
  update public.profiles set role='OPERATOR',access_mode='FULL',is_active=true,deleted_at=null,
    must_change_password=false where id=v_operator;
  update public.profiles set role='OPERATOR',access_mode='REVIEW_ONLY',is_active=true,deleted_at=null,
    access_expires_at=now()+interval '1 hour',must_change_password=false where id=v_review;
  insert into public.customers(full_name,passport_number,created_by,date_of_birth,place_of_birth,nationality,gender,passport_expiry_date)
    values('LEGACY READ SYNTHETIC','READ'||substr(replace(v_owner::text,'-',''),1,12),v_owner,'2000-01-01','TEST','TEST','1','2030-01-01')
    returning id into v_customer;
  insert into public.automation_batches(task_type,created_by,status,note,total_count,entry_date,exit_date)
    values('MDAC_REGISTRATION',v_owner,'SUCCEEDED','read-fixture',1,'2026-10-07','2026-10-08') returning id into v_batch;
  insert into public.automation_items(batch_id,customer_id,status)
    values(v_batch,v_customer,'SUCCEEDED');
  -- Override only selected heartbeat rows inside this transaction; all revert.
  insert into public.worker_heartbeats(worker_id,hostname,version,status,last_seen_at)
    values('read-test-ocr','OWNER-HOST','synthetic','BUSY',now()+interval '1 second')
    on conflict(worker_id) do update set status=excluded.status,last_seen_at=excluded.last_seen_at;
  perform set_config('read_test.owner',v_owner::text,true);
  perform set_config('read_test.operator',v_operator::text,true);
  perform set_config('read_test.review',v_review::text,true);
  perform set_config('read_test.batch',v_batch::text,true);
  perform set_config('read_test.customer',v_customer::text,true);
end $fixtures$;

set local role anon;
do $anon$
begin
  begin perform public.get_workers_health();raise exception 'anon health allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
  begin perform public.get_mdac_batch_memberships();raise exception 'anon memberships allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
end $anon$;
set local role postgres;
set local role service_role;
do $service$
begin
  begin perform public.get_workers_health();raise exception 'unused service health allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
  begin perform public.get_mdac_batch_memberships();raise exception 'unused service memberships allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
end $service$;
set local role postgres;
set local role authenticated;
do $business$
declare v_id text;v_health jsonb;
begin
  foreach v_id in array array[current_setting('read_test.owner'),current_setting('read_test.operator'),current_setting('read_test.review')] loop
    perform set_config('request.jwt.claim.sub',v_id,true);
    if not exists(select 1 from public.get_mdac_batch_memberships() m where m.batch_id=current_setting('read_test.batch')::uuid and m.name='read-fixture' and current_setting('read_test.customer')::uuid=any(m.customer_ids)) then raise exception 'Business membership structure/scope changed';end if;
    v_health:=public.get_workers_health();
    if not (v_health ?& array['mdac','reg_check','visit_pass','ocr','gmail_pin'])
      or v_health#>>'{ocr,status}' is distinct from 'BUSY'
      or (v_health#>>'{ocr,is_online}')::boolean is distinct from true then raise exception 'Health schema or fresh BUSY failed';end if;
    if v_id=current_setting('read_test.owner') then
      if v_health#>>'{ocr,hostname}' is distinct from 'OWNER-HOST' then raise exception 'Owner hostname missing';end if;
    elsif v_health#>>'{ocr,hostname}' is not null then raise exception 'Ordinary user hostname leaked';end if;
  end loop;
  perform set_config('request.jwt.claim.sub','',true);
  begin perform public.get_workers_health();raise exception 'Missing user health allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
  begin perform public.get_mdac_batch_memberships();raise exception 'Missing user memberships allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
end $business$;
set local role postgres;
do $invalid_profiles$
declare v_state text;v_id uuid:=current_setting('read_test.operator')::uuid;
begin
  foreach v_state in array array['INACTIVE','DELETED','EXPIRED','MISSING'] loop
    perform set_config('request.jwt.claim.sub','',true);
    update public.profiles set is_active=true,deleted_at=null,access_mode='FULL',access_expires_at=null where id=v_id;
    if v_state='INACTIVE' then update public.profiles set is_active=false where id=v_id;
    elsif v_state='DELETED' then update public.profiles set deleted_at=now() where id=v_id;
    elsif v_state='EXPIRED' then update public.profiles set access_mode='REVIEW_ONLY',access_expires_at=now()-interval '1 minute' where id=v_id;
    else v_id:=gen_random_uuid();end if;
    perform set_config('request.jwt.claim.sub',v_id::text,true);
    execute 'set local role authenticated';
    begin perform public.get_workers_health();raise exception 'Invalid profile health allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
    begin perform public.get_mdac_batch_memberships();raise exception 'Invalid profile memberships allowed' using errcode='ZZ001';exception when insufficient_privilege then null;end;
    execute 'set local role postgres';
  end loop;
  -- Fresh ONLINE can be false if the heartbeat has aged out.
  perform set_config('request.jwt.claim.sub','',true);
  update public.worker_heartbeats set last_seen_at=now()-interval '10 minutes',status='ONLINE' where worker_id like '%ocr%';
  perform set_config('request.jwt.claim.sub',current_setting('read_test.owner'),true);
  if (public.get_workers_health()#>>'{ocr,is_online}')::boolean is distinct from false then raise exception 'Stale ONLINE accepted';end if;
end $invalid_profiles$;
do $acl$
declare r record;
begin
  for r in select p.oid,p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('get_workers_health','get_mdac_batch_memberships') loop
    if has_function_privilege('anon',r.oid,'EXECUTE') or has_function_privilege('service_role',r.oid,'EXECUTE') or not ('search_path=""'=any(r.proconfig)) then raise exception 'ACL/search_path regression';end if;
    if exists(select 1 from aclexplode((select proacl from pg_proc where oid=r.oid)) where grantee=0 and privilege_type='EXECUTE') then raise exception 'PUBLIC execute survived';end if;
  end loop;
end $acl$;
rollback;
