create or replace function public.create_customer_with_case(
  p_full_name text,
  p_passport_number text,
  p_date_of_birth date,
  p_place_of_birth text,
  p_nationality text,
  p_gender text,
  p_passport_expiry_date date,
  p_passport_image_path text default null,
  p_customer_type public.customer_type default 'STANDARD'
) returns jsonb
language plpgsql
security invoker
set search_path to 'public','pg_temp'
as $function$
declare
  v_customer public.customers;
  v_passport public.passports;
  v_case public.customer_cases;
  v_actor uuid := (select auth.uid());
  v_passport_number text := upper(trim(coalesce(p_passport_number,'')));
begin
  if not private.is_active_user() then raise exception 'active user required'; end if;
  if v_actor is null then raise exception 'authenticated user required'; end if;
  if nullif(trim(p_full_name),'') is null or v_passport_number='' then
    raise exception 'full name and passport number are required';
  end if;
  if exists (
    select 1 from public.passports p join public.customers c on c.id=p.customer_id
    where p.is_active and c.deleted_at is null
      and upper(regexp_replace(p.passport_number,'[^A-Z0-9]','','g')) =
          upper(regexp_replace(v_passport_number,'[^A-Z0-9]','','g'))
  ) then
    raise exception 'active passport already belongs to an existing customer';
  end if;

  insert into public.customers(
    full_name,passport_number,date_of_birth,place_of_birth,nationality,gender,
    passport_expiry_date,passport_image_path,business_status,created_by,
    customer_type,retention_policy,last_active_at,customer_status
  ) values (
    upper(trim(p_full_name)),v_passport_number,p_date_of_birth,upper(trim(p_place_of_birth)),
    upper(trim(p_nationality)),trim(p_gender),p_passport_expiry_date,
    nullif(trim(p_passport_image_path),''),'PENDING',v_actor,p_customer_type,
    case when p_customer_type='A' then 'LONG_TERM'::public.customer_retention_policy
         else 'STANDARD_6_MONTHS'::public.customer_retention_policy end,
    now(),'ACTIVE'
  ) returning * into v_customer;

  insert into public.passports(
    customer_id,passport_number,passport_expiry_date,passport_image_path,
    is_active,source_customer_id,created_by
  ) values (
    v_customer.id,v_passport_number,p_passport_expiry_date,
    nullif(trim(p_passport_image_path),''),true,v_customer.id,v_actor
  ) returning * into v_passport;

  insert into public.customer_cases(
    customer_id,passport_id,case_status,source_customer_id,created_by
  ) values (
    v_customer.id,v_passport.id,'NEW',v_customer.id,v_actor
  ) returning * into v_case;

  return jsonb_build_object(
    'customer',to_jsonb(v_customer),
    'passport',to_jsonb(v_passport),
    'case',to_jsonb(v_case)
  );
end $function$;

create or replace function public.create_case_for_existing_customer(
  p_customer_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path to 'public','pg_temp'
as $function$
declare
  v_customer public.customers;
  v_passport public.passports;
  v_case public.customer_cases;
  v_actor uuid := (select auth.uid());
begin
  if not private.is_active_user() then raise exception 'active user required'; end if;
  select * into v_customer from public.customers
   where id=p_customer_id and deleted_at is null and customer_status='ACTIVE';
  if not found then raise exception 'customer is missing or inactive'; end if;

  select * into v_passport from public.passports
   where customer_id=p_customer_id and is_active
   order by updated_at desc limit 1;
  if not found then raise exception 'customer has no active passport'; end if;
  if v_passport.passport_expiry_date < current_date then
    raise exception 'active passport is expired; upload a new passport first';
  end if;

  insert into public.customer_cases(customer_id,passport_id,case_status,created_by)
  values(v_customer.id,v_passport.id,'NEW',v_actor)
  returning * into v_case;

  update public.customers set last_active_at=now(),updated_by=v_actor,updated_at=now()
   where id=v_customer.id;
  return jsonb_build_object('case',to_jsonb(v_case),'customer_id',v_customer.id,'passport_id',v_passport.id);
end $function$;

revoke all on function public.create_customer_with_case(text,text,date,text,text,text,date,text,public.customer_type) from public,anon;
grant execute on function public.create_customer_with_case(text,text,date,text,text,text,date,text,public.customer_type) to authenticated;
revoke all on function public.create_case_for_existing_customer(uuid) from public,anon;
grant execute on function public.create_case_for_existing_customer(uuid) to authenticated;

