begin;
create schema visit_legacy_date_acceptance_20261028;
create table visit_legacy_date_acceptance_20261028.automation_batches(id uuid primary key,visit_pass_settings_snapshot jsonb,task_type text,locked_by text,lease_expires_at timestamptz,entry_date date);
create table visit_legacy_date_acceptance_20261028.automation_items(id uuid primary key,batch_id uuid,customer_id uuid,case_id uuid,customer_snapshot jsonb,locked_by text,status text);
create table visit_legacy_date_acceptance_20261028.email_pin_records(id uuid primary key,customer_id uuid,case_id uuid,status text,pin_value text,received_at timestamptz,created_at timestamptz);
create table visit_legacy_date_acceptance_20261028.mdac_registrations(id uuid primary key,customer_id uuid,case_id uuid,entry_date date,submitted_at timestamptz,created_at timestamptz,batch_item_id uuid,registration_status text);
create table visit_legacy_date_acceptance_20261028.customers(id uuid primary key,passport_number text,website_archived_at timestamptz,deleted_at timestamptz);
create table visit_legacy_date_acceptance_20261028.passports(id uuid primary key,customer_id uuid,passport_number text,updated_at timestamptz);
create table visit_legacy_date_acceptance_20261028.customer_cases(id uuid primary key,customer_id uuid,passport_id uuid,created_at timestamptz,website_archived_at timestamptz,arrival_date date);
create table visit_legacy_date_acceptance_20261028.checks(name text,passed boolean);
CREATE OR REPLACE FUNCTION visit_legacy_date_acceptance_20261028.get_visit_pass_check_runtime_input(p_item_id uuid, p_worker_id text)
 RETURNS TABLE(passport_number text, nationality text, email text, region_code text, mobile text, pin_value text, entry_date date, case_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_item_id is null or nullif(trim(p_worker_id), '') is null then
    raise exception 'item_id and worker_id are required';
  end if;

  return query
  select
    trim(i.customer_snapshot ->> 'passport_number'),
    upper(trim(i.customer_snapshot ->> 'nationality')),
    lower(trim(b.visit_pass_settings_snapshot ->> 'email')),
    trim(b.visit_pass_settings_snapshot ->> 'region_code'),
    trim(b.visit_pass_settings_snapshot ->> 'mobile'),
    pin.pin_value,
    coalesce(b.entry_date, mdac.entry_date, legacy_mdac.entry_date),
    i.case_id
  from visit_legacy_date_acceptance_20261028.automation_items i
  join visit_legacy_date_acceptance_20261028.automation_batches b on b.id = i.batch_id
  join lateral (
    select p.pin_value
    from visit_legacy_date_acceptance_20261028.email_pin_records p
    where p.status = 'RECEIVED'
      and nullif(trim(p.pin_value), '') is not null
      and (
        (i.case_id is not null and p.case_id = i.case_id)
        or
        (i.case_id is null and p.customer_id = i.customer_id)
      )
    order by p.received_at desc nulls last, p.created_at desc, p.id desc
    limit 1
  ) pin on true
  left join lateral (
    select m.entry_date
    from visit_legacy_date_acceptance_20261028.mdac_registrations m
    where (
        (i.case_id is not null and m.case_id = i.case_id)
        or
        (i.case_id is null and m.customer_id = i.customer_id)
      )
    order by m.submitted_at desc nulls last, m.created_at desc, m.id desc
    limit 1
  ) mdac on true
  left join lateral (
    select m.entry_date
    from visit_legacy_date_acceptance_20261028.customer_cases cc
    join visit_legacy_date_acceptance_20261028.customers c on c.id=cc.customer_id
    join visit_legacy_date_acceptance_20261028.passports pa on pa.id=cc.passport_id and pa.customer_id=c.id
    join visit_legacy_date_acceptance_20261028.mdac_registrations m on m.customer_id=c.id and m.case_id is null
    join visit_legacy_date_acceptance_20261028.automation_items original_i on original_i.id=m.batch_item_id and original_i.customer_id=c.id and original_i.case_id is null
    join visit_legacy_date_acceptance_20261028.automation_batches original_b on original_b.id=original_i.batch_id and original_b.task_type='MDAC_REGISTRATION'
    where i.case_id is not null and cc.id=i.case_id and cc.customer_id=i.customer_id
      and cc.website_archived_at is null and c.website_archived_at is null and c.deleted_at is null
      and m.registration_status='SUCCEEDED' and original_i.status='SUCCEEDED' and m.entry_date is not null
      and (select count(*) from visit_legacy_date_acceptance_20261028.customer_cases x where x.customer_id=c.id)=1
      and (select count(*) from visit_legacy_date_acceptance_20261028.mdac_registrations x where x.customer_id=c.id)=1
      and upper(trim(pa.passport_number))=upper(trim(c.passport_number))
      and upper(trim(pa.passport_number))=upper(trim(i.customer_snapshot->>'passport_number'))
      and upper(trim(pa.passport_number))=upper(trim(original_i.customer_snapshot->>'passport_number'))
      and coalesce(m.submitted_at,m.created_at)>=cc.created_at
      and coalesce(m.submitted_at,m.created_at)>=pa.updated_at
      and (cc.arrival_date is null or cc.arrival_date=m.entry_date)
  ) legacy_mdac on b.entry_date is null and mdac.entry_date is null
  where i.id = p_item_id
    and i.locked_by = p_worker_id
    and i.status in ('CLAIMED', 'RUNNING')
    and b.task_type = 'VISIT_PASS_CHECK'
    and coalesce(b.entry_date, mdac.entry_date, legacy_mdac.entry_date) is not null
    and b.locked_by = p_worker_id
    and b.lease_expires_at > now()
    and nullif(trim(b.visit_pass_settings_snapshot ->> 'email'), '') is not null
    and nullif(trim(b.visit_pass_settings_snapshot ->> 'region_code'), '') is not null
    and nullif(trim(b.visit_pass_settings_snapshot ->> 'mobile'), '') is not null;

  if not found then
    raise exception 'runtime input unavailable for item or worker lease';
  end if;
end
$function$;


create function visit_legacy_date_acceptance_20261028.expect_unavailable(label text,item_id uuid,worker_id text default 'test-worker') returns void language plpgsql as $test$
begin
 perform 1 from visit_legacy_date_acceptance_20261028.get_visit_pass_check_runtime_input(item_id,worker_id);
 insert into visit_legacy_date_acceptance_20261028.checks values(label,false);
exception when raise_exception then
 if sqlerrm='runtime input unavailable for item or worker lease' then insert into visit_legacy_date_acceptance_20261028.checks values(label,true); else raise; end if;
end $test$;
do $cases$
declare bid uuid:=gen_random_uuid(); iid uuid:=gen_random_uuid(); cid uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid(); pid uuid:=gen_random_uuid(); mid uuid:=gen_random_uuid(); obid uuid:=gen_random_uuid(); oiid uuid:=gen_random_uuid(); extra uuid:=gen_random_uuid(); r record;
begin
 insert into visit_legacy_date_acceptance_20261028.customers values(cid,'SYNTHETIC',null,null);
 insert into visit_legacy_date_acceptance_20261028.passports values(pid,cid,'SYNTHETIC','2026-10-27');
 insert into visit_legacy_date_acceptance_20261028.customer_cases values(oid,cid,pid,'2026-10-27',null,null);
 insert into visit_legacy_date_acceptance_20261028.automation_batches values(bid,'{"email":"synthetic@example.test","region_code":"86","mobile":"10000"}','VISIT_PASS_CHECK','test-worker',now()+interval '10 minutes',null),(obid,null,'MDAC_REGISTRATION',null,null,null);
 insert into visit_legacy_date_acceptance_20261028.automation_items values(iid,bid,cid,oid,'{"passport_number":"SYNTHETIC","nationality":"CHN"}','test-worker','RUNNING'),(oiid,obid,cid,null,'{"passport_number":"SYNTHETIC"}',null,'SUCCEEDED');
 insert into visit_legacy_date_acceptance_20261028.email_pin_records values(gen_random_uuid(),cid,oid,'RECEIVED','TEST-ONLY',now(),now());
 insert into visit_legacy_date_acceptance_20261028.mdac_registrations values(mid,cid,null,date '2026-10-28','2026-10-27 10:00+00','2026-10-27 10:00+00',oiid,'SUCCEEDED');
 select * into r from visit_legacy_date_acceptance_20261028.get_visit_pass_check_runtime_input(iid,'test-worker');
 insert into visit_legacy_date_acceptance_20261028.checks values('proven sole legacy registration provides real date',r.entry_date=date '2026-10-28' and r.case_id=oid);
 insert into visit_legacy_date_acceptance_20261028.checks select 'history remains unmodified and no registration cloned',count(*)=1 and bool_and(case_id is null) from visit_legacy_date_acceptance_20261028.mdac_registrations;
 insert into visit_legacy_date_acceptance_20261028.customer_cases values(extra,cid,pid,'2026-10-27',null,null);
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('multiple Cases are never guessed',iid);
 delete from visit_legacy_date_acceptance_20261028.customer_cases where id=extra;
 insert into visit_legacy_date_acceptance_20261028.mdac_registrations select extra,customer_id,case_id,entry_date,submitted_at,created_at,batch_item_id,registration_status from visit_legacy_date_acceptance_20261028.mdac_registrations where id=mid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('multiple registrations are never guessed',iid);
 delete from visit_legacy_date_acceptance_20261028.mdac_registrations where id=extra;
 update visit_legacy_date_acceptance_20261028.automation_items set customer_snapshot='{"passport_number":"DIFFERENT"}' where id=oiid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('original passport mismatch rejected',iid);
 update visit_legacy_date_acceptance_20261028.automation_items set customer_snapshot='{"passport_number":"SYNTHETIC"}' where id=oiid;
 update visit_legacy_date_acceptance_20261028.passports set updated_at='2026-10-28' where id=pid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('passport changed after registration rejected',iid);
 update visit_legacy_date_acceptance_20261028.passports set updated_at='2026-10-27' where id=pid;
 update visit_legacy_date_acceptance_20261028.customer_cases set created_at='2026-10-28' where id=oid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('registration predating Case rejected',iid);
 update visit_legacy_date_acceptance_20261028.customer_cases set created_at='2026-10-27',arrival_date=date '2026-10-27' where id=oid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('conflicting Case arrival date rejected',iid);
 update visit_legacy_date_acceptance_20261028.customer_cases set arrival_date=null where id=oid;
 update visit_legacy_date_acceptance_20261028.mdac_registrations set registration_status='NEEDS_REVIEW' where id=mid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('unconfirmed registration rejected',iid);
 update visit_legacy_date_acceptance_20261028.mdac_registrations set registration_status='SUCCEEDED' where id=mid;
 update visit_legacy_date_acceptance_20261028.automation_batches set task_type='REGISTRATION_CHECK' where id=obid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('nonregistration source task rejected',iid);
 update visit_legacy_date_acceptance_20261028.automation_batches set task_type='MDAC_REGISTRATION' where id=obid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('wrong worker still rejected',iid,'other-worker');
 update visit_legacy_date_acceptance_20261028.automation_batches set lease_expires_at=now()-interval '1 second' where id=bid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('expired lease still rejected',iid);
 update visit_legacy_date_acceptance_20261028.automation_batches set lease_expires_at=now()+interval '10 minutes',entry_date=date '2026-10-27' where id=bid;
 select * into r from visit_legacy_date_acceptance_20261028.get_visit_pass_check_runtime_input(iid,'test-worker');
 insert into visit_legacy_date_acceptance_20261028.checks values('explicit batch override retains priority',r.entry_date=date '2026-10-27');
 update visit_legacy_date_acceptance_20261028.automation_batches set entry_date=null where id=bid;
 update visit_legacy_date_acceptance_20261028.mdac_registrations set case_id=extra where id=mid;
 perform visit_legacy_date_acceptance_20261028.expect_unavailable('registration from another Case rejected',iid);
 update visit_legacy_date_acceptance_20261028.mdac_registrations set case_id=oid where id=mid;
 select * into r from visit_legacy_date_acceptance_20261028.get_visit_pass_check_runtime_input(iid,'test-worker');
 insert into visit_legacy_date_acceptance_20261028.checks values('same Case registration path preserved',r.entry_date=date '2026-10-28');
 if exists(select 1 from visit_legacy_date_acceptance_20261028.checks where passed is not true) then raise exception 'verified legacy date tests failed'; end if;
end $cases$;
select jsonb_build_object('passed',count(*) filter(where passed),'failed',count(*) filter(where passed is not true),'checks',jsonb_agg(to_jsonb(c))) as isolated_tests from visit_legacy_date_acceptance_20261028.checks c;
rollback;
