begin;
create schema visit_date_acceptance_20261028;
create table visit_date_acceptance_20261028.automation_batches(id uuid primary key,visit_pass_settings_snapshot jsonb,task_type text,locked_by text,lease_expires_at timestamptz,entry_date date);
create table visit_date_acceptance_20261028.automation_items(id uuid primary key,batch_id uuid,customer_id uuid,case_id uuid,customer_snapshot jsonb,locked_by text,status text);
create table visit_date_acceptance_20261028.email_pin_records(id uuid primary key,customer_id uuid,case_id uuid,status text,pin_value text,received_at timestamptz,created_at timestamptz);
create table visit_date_acceptance_20261028.mdac_registrations(id uuid primary key,customer_id uuid,case_id uuid,entry_date date,submitted_at timestamptz,created_at timestamptz);
create table visit_date_acceptance_20261028.checks(name text,passed boolean);
CREATE OR REPLACE FUNCTION visit_date_acceptance_20261028.get_visit_pass_check_runtime_input(p_item_id uuid, p_worker_id text)
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
    coalesce(b.entry_date, mdac.entry_date),
    i.case_id
  from visit_date_acceptance_20261028.automation_items i
  join visit_date_acceptance_20261028.automation_batches b on b.id = i.batch_id
  join lateral (
    select p.pin_value
    from visit_date_acceptance_20261028.email_pin_records p
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
    from visit_date_acceptance_20261028.mdac_registrations m
    where (
        (i.case_id is not null and m.case_id = i.case_id)
        or
        (i.case_id is null and m.customer_id = i.customer_id)
      )
    order by m.submitted_at desc nulls last, m.created_at desc, m.id desc
    limit 1
  ) mdac on true
  where i.id = p_item_id
    and i.locked_by = p_worker_id
    and i.status in ('CLAIMED', 'RUNNING')
    and b.task_type = 'VISIT_PASS_CHECK'
    and coalesce(b.entry_date, mdac.entry_date) is not null
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

create function visit_date_acceptance_20261028.expect_unavailable(label text,item_id uuid,worker_id text) returns void language plpgsql as $test$
begin
 perform 1 from visit_date_acceptance_20261028.get_visit_pass_check_runtime_input(item_id,worker_id);
 insert into visit_date_acceptance_20261028.checks values(label,false);
exception when raise_exception then
 if sqlerrm='runtime input unavailable for item or worker lease' then insert into visit_date_acceptance_20261028.checks values(label,true); else raise; end if;
end $test$;
do $cases$
declare bid uuid:=gen_random_uuid(); iid uuid:=gen_random_uuid(); cid uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid(); r record;
begin
 insert into visit_date_acceptance_20261028.automation_batches values(bid,'{"email":"synthetic@example.test","region_code":"86","mobile":"10000000000"}','VISIT_PASS_CHECK','test-worker',clock_timestamp()+interval '10 minutes',date '2026-10-27');
 insert into visit_date_acceptance_20261028.automation_items values(iid,bid,cid,oid,'{"passport_number":"SYNTHETIC","nationality":"CHN"}','test-worker','RUNNING');
 insert into visit_date_acceptance_20261028.email_pin_records values(gen_random_uuid(),cid,oid,'RECEIVED','TEST-ONLY',now(),now());
 select * into r from visit_date_acceptance_20261028.get_visit_pass_check_runtime_input(iid,'test-worker');
 insert into visit_date_acceptance_20261028.checks values('explicit batch date works without MDAC record',r.entry_date=date '2026-10-27' and r.case_id=oid);
 insert into visit_date_acceptance_20261028.checks values('no registration record fabricated',(select count(*)=0 from visit_date_acceptance_20261028.mdac_registrations));
 perform visit_date_acceptance_20261028.expect_unavailable('wrong worker rejected',iid,'other-worker');
 update visit_date_acceptance_20261028.automation_batches set lease_expires_at=now()-interval '1 second' where id=bid;
 perform visit_date_acceptance_20261028.expect_unavailable('expired lease rejected',iid,'test-worker');
 update visit_date_acceptance_20261028.automation_batches set lease_expires_at=now()+interval '10 minutes',task_type='MDAC_REGISTRATION' where id=bid;
 perform visit_date_acceptance_20261028.expect_unavailable('wrong task type rejected',iid,'test-worker');
 update visit_date_acceptance_20261028.automation_batches set task_type='VISIT_PASS_CHECK',entry_date=null where id=bid;
 perform visit_date_acceptance_20261028.expect_unavailable('missing all date sources rejected',iid,'test-worker');
 insert into visit_date_acceptance_20261028.mdac_registrations values(gen_random_uuid(),cid,gen_random_uuid(),date '2026-10-25',now(),now());
 perform visit_date_acceptance_20261028.expect_unavailable('other Case date never reused',iid,'test-worker');
 insert into visit_date_acceptance_20261028.mdac_registrations values(gen_random_uuid(),cid,oid,date '2026-10-26',now(),now());
 select * into r from visit_date_acceptance_20261028.get_visit_pass_check_runtime_input(iid,'test-worker');
 insert into visit_date_acceptance_20261028.checks values('existing same Case MDAC fallback preserved',r.entry_date=date '2026-10-26');
 update visit_date_acceptance_20261028.automation_batches set entry_date=date '2026-10-27' where id=bid;
 select * into r from visit_date_acceptance_20261028.get_visit_pass_check_runtime_input(iid,'test-worker');
 insert into visit_date_acceptance_20261028.checks values('explicit batch date takes precedence',r.entry_date=date '2026-10-27');
 update visit_date_acceptance_20261028.email_pin_records set case_id=null;
 perform visit_date_acceptance_20261028.expect_unavailable('customer-only PIN cannot bypass Case matching',iid,'test-worker');
 if exists(select 1 from visit_date_acceptance_20261028.checks where passed is not true) then raise exception 'visit date acceptance failure'; end if;
end $cases$;
select jsonb_build_object('passed',count(*) filter(where passed),'failed',count(*) filter(where passed is not true),'checks',jsonb_agg(to_jsonb(c))) as isolated_tests from visit_date_acceptance_20261028.checks c;
rollback;
