-- Migration: 20260908193000_allow_custom_region_code.sql
-- Description: Allow customizable country/region calling code (1-4 digits) in MDAC settings instead of hardcoding to 60.

alter table public.mdac_settings
  drop constraint if exists mdac_settings_region_code_check;

alter table public.mdac_settings
  add constraint mdac_settings_region_code_check
  check (region_code ~ '^[0-9]{1,4}$');

create or replace function public.update_mdac_settings(
  p_mdac_email text,
  p_mdac_phone text,
  p_region_code text,
  p_travel_mode text,
  p_embark_country text,
  p_vessel text,
  p_accommodation_stay text,
  p_address1 text,
  p_address2 text default '',
  p_state_code text default '',
  p_city_code text default '',
  p_postcode text default '',
  p_pob_mode text default 'NATIONALITY'
)
returns public.mdac_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.mdac_settings;
  v_email text := trim(coalesce(p_mdac_email, ''));
  v_phone text := trim(coalesce(p_mdac_phone, ''));
  v_region text := trim(coalesce(p_region_code, ''));
  v_travel text := trim(coalesce(p_travel_mode, ''));
  v_embark text := upper(trim(coalesce(p_embark_country, '')));
  v_vessel text := trim(coalesce(p_vessel, ''));
  v_stay text := trim(coalesce(p_accommodation_stay, ''));
  v_address1 text := trim(coalesce(p_address1, ''));
  v_address2 text := trim(coalesce(p_address2, ''));
  v_state text := trim(coalesce(p_state_code, ''));
  v_city text := trim(coalesce(p_city_code, ''));
  v_postcode text := trim(coalesce(p_postcode, ''));
  v_pob text := upper(trim(coalesce(p_pob_mode, 'NATIONALITY')));
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;
  if v_email = '' or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'valid MDAC email is required';
  end if;
  if v_phone = '' or length(v_phone) > 40 then
    raise exception 'valid MDAC phone is required';
  end if;
  if v_region !~ '^[0-9]{1,4}$' then
    raise exception 'valid region_code is required (1-4 digits)';
  end if;
  if v_travel not in ('1', '2', '3') then
    raise exception 'travel_mode must be 1, 2, or 3';
  end if;
  if v_embark !~ '^[A-Z]{3}$' then
    raise exception 'embark_country must be a three-letter uppercase code';
  end if;
  if v_vessel = '' or length(v_vessel) > 30 then
    raise exception 'vessel is required';
  end if;
  if v_stay not in ('01', '02', '99') then
    raise exception 'accommodation_stay must be 01, 02, or 99';
  end if;
  if v_address1 = '' or length(v_address1) > 100 then
    raise exception 'address1 is required';
  end if;
  if length(v_address2) > 100 then
    raise exception 'address2 cannot exceed 100 characters';
  end if;
  if v_state !~ '^[0-9]{2}$' then
    raise exception 'state_code must be a two-digit code';
  end if;
  if v_city !~ '^[0-9]{4}$' then
    raise exception 'city_code must be a four-digit code';
  end if;
  if length(v_postcode) > 5 then
    raise exception 'postcode cannot exceed 5 characters';
  end if;
  if v_pob not in ('NATIONALITY', 'CUSTOMER') then
    raise exception 'pob_mode must be NATIONALITY or CUSTOMER';
  end if;

  insert into public.mdac_settings (
    id, mdac_email, mdac_phone, region_code, travel_mode, embark_country,
    vessel, accommodation_stay, address1, address2, state_code, city_code,
    postcode, pob_mode, updated_by
  ) values (
    true, v_email, v_phone, v_region, v_travel, v_embark,
    v_vessel, v_stay, v_address1, v_address2, v_state, v_city,
    v_postcode, v_pob, auth.uid()
  )
  on conflict (id) do update set
    mdac_email = excluded.mdac_email,
    mdac_phone = excluded.mdac_phone,
    region_code = excluded.region_code,
    travel_mode = excluded.travel_mode,
    embark_country = excluded.embark_country,
    vessel = excluded.vessel,
    accommodation_stay = excluded.accommodation_stay,
    address1 = excluded.address1,
    address2 = excluded.address2,
    state_code = excluded.state_code,
    city_code = excluded.city_code,
    postcode = excluded.postcode,
    pob_mode = excluded.pob_mode,
    updated_by = excluded.updated_by
  returning * into v_settings;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    auth.uid(),
    'UPDATE_MDAC_SETTINGS',
    'mdac_settings',
    null,
    jsonb_build_object(
      'email', v_email,
      'phone', v_phone,
      'region_code', v_region,
      'travel_mode', v_travel,
      'embark_country', v_embark,
      'pob_mode', v_pob
    )
  );

  return v_settings;
end;
$$;
