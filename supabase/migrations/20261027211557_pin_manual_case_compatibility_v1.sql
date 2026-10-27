create function private.bind_unambiguous_manual_pin_case_v1()
returns trigger language plpgsql security definer set search_path='' as $pin$
declare v_case uuid; v_cases integer;
begin
 if new.case_id is not null or new.batch_item_id is not null
    or new.status::text<>'RECEIVED' or nullif(btrim(new.pin_value),'') is null then return new; end if;
 perform 1 from public.customers where id=new.customer_id for update;
 select count(*) into v_cases from public.customer_cases where customer_id=new.customer_id;
 if v_cases<>1 then return new; end if;
 select cc.id into v_case from public.customer_cases cc
 join public.customers c on c.id=cc.customer_id
 join public.passports p on p.id=cc.passport_id and p.customer_id=c.id
 where cc.customer_id=new.customer_id and cc.website_archived_at is null
 and cc.business_status is null and c.deleted_at is null and c.website_archived_at is null
 and upper(btrim(p.passport_number))=upper(btrim(c.passport_number))
 and coalesce(new.received_at,new.created_at,clock_timestamp())>=cc.created_at
 and coalesce(new.received_at,new.created_at,clock_timestamp())>=p.updated_at;
 if found then new.case_id:=v_case; end if;
 return new;
end $pin$;
revoke all on function private.bind_unambiguous_manual_pin_case_v1() from public,anon,authenticated,service_role;
create trigger email_pin_manual_case_compat_v1 before insert or update of customer_id,case_id,pin_value,status,received_at
on public.email_pin_records for each row execute function private.bind_unambiguous_manual_pin_case_v1();

