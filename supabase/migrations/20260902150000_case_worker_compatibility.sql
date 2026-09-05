-- Phase 3 compatibility: legacy App/RPC/Workers keep customer_id while every
-- new workflow is attached to the current Case automatically.

create or replace function private.assign_automation_item_case()
returns trigger language plpgsql security definer
set search_path to 'public','private','pg_temp'
as $function$
begin
  if new.case_id is not null then
    if not exists(select 1 from public.customer_cases c where c.id=new.case_id and c.customer_id=new.customer_id) then
      raise exception 'case does not belong to automation customer';
    end if;
    return new;
  end if;
  select c.id into new.case_id
  from public.customer_cases c
  where c.customer_id=new.customer_id
    and c.case_status not in ('COMPLETED','ARCHIVED','CANCELLED')
  order by c.created_at desc limit 1;
  return new;
end $function$;
revoke all on function private.assign_automation_item_case() from public,anon,authenticated;

drop trigger if exists automation_items_assign_case on public.automation_items;
create trigger automation_items_assign_case
before insert or update of customer_id,case_id on public.automation_items
for each row execute function private.assign_automation_item_case();

create or replace function private.sync_case_from_automation_item()
returns trigger language plpgsql security definer
set search_path to 'public','private','pg_temp'
as $function$
declare v_batch public.automation_batches;
begin
  if new.case_id is null then return new; end if;
  select * into v_batch from public.automation_batches where id=new.batch_id;
  update public.customer_cases c set
    arrival_date=case when v_batch.task_type='MDAC_REGISTRATION' then coalesce(v_batch.entry_date,c.arrival_date) else c.arrival_date end,
    departure_date=case when v_batch.task_type='MDAC_REGISTRATION' then coalesce(v_batch.exit_date,c.departure_date) else c.departure_date end,
    case_status=case v_batch.task_type::text
      when 'MDAC_REGISTRATION' then 'MDAC_PROCESSING'::public.case_status
      when 'GMAIL_PIN' then 'WAITING_PIN'::public.case_status
      when 'REGISTRATION_CHECK' then 'WAITING_REGISTRATION'::public.case_status
      when 'VISIT_PASS_CHECK' then 'WAITING_VISIT_PASS'::public.case_status
      else c.case_status end,
    updated_at=now()
  where c.id=new.case_id;
  return new;
end $function$;
revoke all on function private.sync_case_from_automation_item() from public,anon,authenticated;

drop trigger if exists automation_items_sync_case on public.automation_items;
create trigger automation_items_sync_case
after insert on public.automation_items
for each row execute function private.sync_case_from_automation_item();

create or replace function private.assign_result_case()
returns trigger language plpgsql security definer
set search_path to 'public','private','pg_temp'
as $function$
declare v_case_id uuid; v_customer_id uuid;
begin
  select i.case_id,i.customer_id into v_case_id,v_customer_id
  from public.automation_items i where i.id=new.batch_item_id;
  if not found then raise exception 'automation item not found'; end if;
  if new.customer_id<>v_customer_id then raise exception 'result customer does not match automation item'; end if;
  if new.case_id is null then new.case_id:=v_case_id;
  elsif v_case_id is not null and new.case_id<>v_case_id then
    raise exception 'result case does not match automation item';
  end if;
  return new;
end $function$;
revoke all on function private.assign_result_case() from public,anon,authenticated;

drop trigger if exists mdac_registrations_assign_case on public.mdac_registrations;
create trigger mdac_registrations_assign_case before insert or update of batch_item_id,customer_id,case_id
on public.mdac_registrations for each row execute function private.assign_result_case();
drop trigger if exists registration_checks_assign_case on public.registration_checks;
create trigger registration_checks_assign_case before insert or update of batch_item_id,customer_id,case_id
on public.registration_checks for each row execute function private.assign_result_case();
drop trigger if exists visit_pass_checks_assign_case on public.visit_pass_checks;
create trigger visit_pass_checks_assign_case before insert or update of batch_item_id,customer_id,case_id
on public.visit_pass_checks for each row execute function private.assign_result_case();
drop trigger if exists email_pin_records_assign_case on public.email_pin_records;
create trigger email_pin_records_assign_case before insert or update of batch_item_id,customer_id,case_id
on public.email_pin_records for each row
when (new.batch_item_id is not null)
execute function private.assign_result_case();

create or replace function private.sync_case_status_from_customer()
returns trigger language plpgsql security definer
set search_path to 'public','private','pg_temp'
as $function$
declare v_status public.case_status;
begin
  v_status:=case new.business_status::text
    when 'PENDING' then 'NEW'::public.case_status
    when 'MDAC_REGISTERING' then 'MDAC_PROCESSING'::public.case_status
    when 'MDAC_REGISTERED' then 'MDAC_COMPLETED'::public.case_status
    when 'PIN_PENDING' then 'WAITING_PIN'::public.case_status
    when 'PIN_RECEIVED' then 'PIN_READY'::public.case_status
    when 'REGISTRATION_CHECKED' then 'REGISTRATION_COMPLETED'::public.case_status
    when 'VISIT_PASS_CHECKED' then 'VISIT_PASS_COMPLETED'::public.case_status
    when 'ACTION_REQUIRED' then 'ACTION_REQUIRED'::public.case_status
    when 'ARCHIVED' then 'ARCHIVED'::public.case_status
    else null end;
  if v_status is not null then
    update public.customer_cases c set case_status=v_status,updated_at=now()
    where c.id=(
      select x.id from public.customer_cases x
      where x.customer_id=new.id and x.case_status not in ('COMPLETED','ARCHIVED','CANCELLED')
      order by x.created_at desc limit 1
    );
  end if;
  return new;
end $function$;
revoke all on function private.sync_case_status_from_customer() from public,anon,authenticated;

drop trigger if exists customers_sync_case_status on public.customers;
create trigger customers_sync_case_status
after update of business_status on public.customers
for each row when (old.business_status is distinct from new.business_status)
execute function private.sync_case_status_from_customer();

create or replace function private.capture_verified_customer_pin()
returns trigger language plpgsql security definer
set search_path to 'public','private','pg_temp'
as $function$
begin
  if new.status='RECEIVED' and nullif(trim(new.pin_value),'') is not null then
    insert into private.customer_mdac_profiles(
      customer_id,pin_value,pin_status,last_verified_at,source
    ) values (
      new.customer_id,new.pin_value,'VERIFIED',coalesce(new.received_at,now()),'GMAIL_WORKER'
    )
    on conflict(customer_id) do update set
      pin_value=excluded.pin_value,
      pin_status='VERIFIED',
      last_verified_at=excluded.last_verified_at,
      source=excluded.source,
      updated_at=now();
  end if;
  return new;
end $function$;
revoke all on function private.capture_verified_customer_pin() from public,anon,authenticated;

drop trigger if exists email_pin_records_capture_profile on public.email_pin_records;
create trigger email_pin_records_capture_profile
after insert or update of status,pin_value on public.email_pin_records
for each row execute function private.capture_verified_customer_pin();

-- Backfill compatibility columns if rows appeared between phase 1 and phase 3.
update public.automation_items i set case_id=(
  select cc.id from public.customer_cases cc where cc.customer_id=i.customer_id
  order by cc.created_at desc limit 1
) where i.case_id is null;
update public.mdac_registrations r set case_id=i.case_id
from public.automation_items i where r.batch_item_id=i.id and r.case_id is null;
update public.registration_checks r set case_id=i.case_id
from public.automation_items i where r.batch_item_id=i.id and r.case_id is null;
update public.visit_pass_checks r set case_id=i.case_id
from public.automation_items i where r.batch_item_id=i.id and r.case_id is null;
update public.email_pin_records r set case_id=i.case_id
from public.automation_items i where r.batch_item_id=i.id and r.case_id is null;

