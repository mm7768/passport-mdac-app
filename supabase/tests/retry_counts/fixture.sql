-- ONLY for mdac-trash-v1-acceptance-20261003, never a production migration.
-- Requires the complete metadata clone in mdac_retry_*_20261027.
create table mdac_retry_app_20261027.test_context(key text primary key,value uuid not null);
create table mdac_retry_app_20261027.test_checks(name text primary key,passed boolean not null,details jsonb default '{}');
create table mdac_retry_app_20261027.test_item_before as select * from mdac_retry_app_20261027.automation_items with no data;
alter table mdac_retry_app_20261027.test_context enable row level security;
alter table mdac_retry_app_20261027.test_checks enable row level security;
alter table mdac_retry_app_20261027.test_item_before enable row level security;
create policy fixture_context_read on mdac_retry_app_20261027.test_context for select to authenticated,service_role using(true);
create policy fixture_before_read on mdac_retry_app_20261027.test_item_before for select to authenticated,service_role using(true);
create policy fixture_checks_access on mdac_retry_app_20261027.test_checks to authenticated,service_role using(true) with check(true);
grant select on mdac_retry_app_20261027.test_context,mdac_retry_app_20261027.test_item_before to authenticated,service_role;
grant select,insert,update on mdac_retry_app_20261027.test_checks to authenticated,service_role;

insert into mdac_retry_app_20261027.auth_users(id) values
('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222'),
('33333333-3333-4333-8333-333333333333'),('44444444-4444-4444-8444-444444444444');
insert into mdac_retry_app_20261027.profiles(id,name,role,is_active,access_mode,access_expires_at) values
('11111111-1111-4111-8111-111111111111','ISOLATED OWNER','OWNER',true,'FULL',null),
('22222222-2222-4222-8222-222222222222','ISOLATED OTHER','OPERATOR',true,'FULL',null),
('33333333-3333-4333-8333-333333333333','ISOLATED INACTIVE','OPERATOR',false,'FULL',null),
('44444444-4444-4444-8444-444444444444','ISOLATED EXPIRED','OPERATOR',true,'REVIEW_ONLY','2020-01-01');

select set_config('request.jwt.claims','{"role":"service_role"}',true);
do $$ declare cid uuid; pid uuid; caseid uuid; bid uuid; itemid uuid; n integer; ownerid uuid:='11111111-1111-4111-8111-111111111111'; begin
 insert into mdac_retry_app_20261027.automation_batches(id,task_type,created_by,status,entry_date,exit_date,attempt_count)
 values('a1000000-0000-4000-8000-000000000001','MDAC_REGISTRATION',ownerid,'QUEUED','2030-01-01','2030-01-02',1) returning id into bid;
 insert into mdac_retry_app_20261027.test_context values('safe_batch',bid);
 for n in 1..20 loop
  insert into mdac_retry_app_20261027.customers(full_name,date_of_birth,place_of_birth,passport_number,nationality,gender,passport_expiry_date,created_by)
  values('ISOLATED TEST '||n,'1990-01-01','CHINA','TEST'||lpad(n::text,6,'0'),'CHN','男','2035-01-01',ownerid) returning id into cid;
  insert into mdac_retry_app_20261027.passports(customer_id,passport_number,passport_expiry_date,created_by)
  values(cid,'TEST'||lpad(n::text,6,'0'),'2035-01-01',ownerid) returning id into pid;
  insert into mdac_retry_app_20261027.customer_cases(customer_id,passport_id,order_no,arrival_date,departure_date,created_by)
  values(cid,pid,'AA'||lpad((900000+n)::text,6,'0'),'2030-01-01','2030-01-02',ownerid) returning id into caseid;
  insert into mdac_retry_app_20261027.automation_items(batch_id,customer_id,case_id,customer_snapshot,status,attempt_count,result_unknown,submission_started_at,error_code)
  values(bid,cid,caseid,jsonb_build_object('full_name','ISOLATED TEST '||n,'passport_number','TEST'||lpad(n::text,6,'0'),'nationality','CHN','gender','男','date_of_birth','1990-01-01','passport_expiry_date','2035-01-01'),
   case when n=20 then 'FAILED' else 'SUCCEEDED' end::mdac_retry_app_20261027.automation_item_status,
   case when n=20 then 2 else 1 end,false,case when n=20 then null else now() end,
   case when n=20 then 'ISOLATED_BEFORE_SUBMIT_FAILURE' else null end) returning id into itemid;
  if n=20 then
   insert into mdac_retry_app_20261027.test_context values('safe_item',itemid),('safe_customer',cid),('safe_case',caseid);
  end if;
 end loop;
 insert into mdac_retry_app_20261027.test_item_before select * from mdac_retry_app_20261027.automation_items;
end $$;
