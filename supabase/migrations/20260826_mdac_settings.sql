-- MDAC business defaults are editable from the Flutter app.
-- Runtime secrets and the fill-only safety mode remain Railway-only.

create table public.mdac_settings (
  id boolean primary key default true check (id = true),
  mdac_email text not null default '' check (length(mdac_email) <= 160),
  mdac_phone text not null default '' check (length(mdac_phone) <= 40),
  region_code text not null default '60' check (region_code in ('60')),
  travel_mode text not null default '2' check (travel_mode in ('1', '2', '3')),
  embark_country text not null default '' check (embark_country = upper(embark_country) and (embark_country = '' or embark_country ~ '^[A-Z]{3}$')),
  vessel text not null default '' check (length(vessel) <= 30),
  accommodation_stay text not null default '02' check (accommodation_stay in ('01', '02', '99')),
  address1 text not null default '' check (length(address1) <= 100),
  address2 text not null default '' check (length(address2) <= 100),
  state_code text not null default '' check (state_code = '' or state_code ~ '^[0-9]{2}$'),
  city_code text not null default '' check (city_code = '' or city_code ~ '^[0-9]{4}$'),
  postcode text not null default '' check (length(postcode) <= 5),
  pob_mode text not null default 'NATIONALITY' check (pob_mode in ('NATIONALITY', 'CUSTOMER')),
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.mdac_settings (id)
values (true)
on conflict (id) do nothing;

create trigger mdac_settings_set_updated_at
before update on public.mdac_settings
for each row execute procedure public.set_updated_at();

alter table public.mdac_settings enable row level security;

create policy mdac_settings_select_active
on public.mdac_settings for select to authenticated
using (private.is_active_user());

create policy mdac_settings_update_active
on public.mdac_settings for update to authenticated
using (private.is_active_user())
with check (private.is_active_user());

comment on table public.mdac_settings is 'Editable MDAC business defaults. Never store service-role keys or submit switches here.';
comment on column public.mdac_settings.mdac_email is 'Business contact email used by the fill-preview form; protected by RLS.';
comment on column public.mdac_settings.mdac_phone is 'Business contact phone used by the fill-preview form; protected by RLS.';

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
  if v_region <> '60' then
    raise exception 'region_code must be 60';
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
  if v_state !~ '^[0-9]{2}$' or v_city !~ '^[0-9]{4}$' then
    raise exception 'state_code and city_code are required';
  end if;
  if v_postcode !~ '^[0-9]{5}$' then
    raise exception 'postcode must contain five digits';
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
    updated_by = auth.uid()
  returning * into v_settings;

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    auth.uid(),
    'MDAC_SETTINGS_UPDATED',
    'mdac_settings',
    null,
    jsonb_build_object(
      'region_code', v_region,
      'travel_mode', v_travel,
      'embark_country', v_embark,
      'accommodation_stay', v_stay,
      'pob_mode', v_pob,
      'email_present', true,
      'phone_present', true
    )
  );

  return v_settings;
end;
$$;

revoke all on function public.update_mdac_settings(text, text, text, text, text, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.update_mdac_settings(text, text, text, text, text, text, text, text, text, text, text, text, text) to authenticated;
