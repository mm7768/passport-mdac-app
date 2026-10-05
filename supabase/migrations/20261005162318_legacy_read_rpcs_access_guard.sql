-- Application backend owns this migration. Apply once; Website references it.
-- Preserve existing shared active-user read scope. No worker calls these RPCs.
create or replace function public.get_mdac_batch_memberships()
returns table(batch_id uuid, name text, created_at timestamptz, customer_ids uuid[])
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role in ('OWNER','OPERATOR')
      and p.is_active and p.deleted_at is null
      and p.access_mode in ('FULL','REVIEW_ONLY')
      and (p.access_expires_at is null or p.access_expires_at > statement_timestamp())
  ) then
    raise exception 'active business user required' using errcode = '42501';
  end if;
  return query
    select b.id, coalesce(nullif(trim(b.note),''),'1'), b.created_at,
      array_agg(i.customer_id order by i.created_at)
    from public.automation_batches b
    join public.automation_items i on i.batch_id = b.id
    where b.task_type = 'MDAC_REGISTRATION'
    group by b.id,b.note,b.created_at order by b.created_at desc;
end $$;

create or replace function public.get_workers_health()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_hostname_allowed boolean;
  v_services jsonb := '{}'::jsonb;
  v_service record;
  v_health jsonb;
begin
  select p.role = 'OWNER' and p.access_mode = 'FULL'
    into v_hostname_allowed from public.profiles p
  where p.id = auth.uid() and p.role in ('OWNER','OPERATOR')
    and p.is_active and p.deleted_at is null
    and p.access_mode in ('FULL','REVIEW_ONLY')
    and (p.access_expires_at is null or p.access_expires_at > statement_timestamp());
  if auth.uid() is null or not found then
    raise exception 'active business user required' using errcode = '42501';
  end if;
  for v_service in select * from (values
    ('mdac','MDAC 自动注册'),('reg_check','登记核验'),
    ('visit_pass','Visit Pass 核验'),('ocr','Azure 护照 OCR'),
    ('gmail_pin','Gmail PIN 抓取')
  ) as services(service_key,display_name) loop
    select jsonb_build_object(
      'name',v_service.display_name,'worker_id',h.worker_id,
      'hostname',case when v_hostname_allowed then h.hostname else null end,
      'status',h.status,'last_seen_at',h.last_seen_at,
      'is_online',h.status::text in ('ONLINE','BUSY')
        and h.last_seen_at >= statement_timestamp()-interval '3 minutes'
    ) into v_health from public.worker_heartbeats h
    where case v_service.service_key
      when 'mdac' then h.worker_id like '%worker-desktop%' or h.worker_id like '%mdac%'
      when 'reg_check' then h.worker_id like '%reg-check%'
      when 'visit_pass' then h.worker_id like '%visit-pass%'
      when 'ocr' then h.worker_id like '%ocr%'
      when 'gmail_pin' then h.worker_id like '%gmail-pin%'
      else false end
    order by h.last_seen_at desc,h.worker_id limit 1;
    v_services := v_services || jsonb_build_object(v_service.service_key,
      coalesce(v_health,jsonb_build_object('name',v_service.display_name,'is_online',false)));
  end loop;
  return v_services;
end $$;

revoke all on function public.get_mdac_batch_memberships(),public.get_workers_health()
  from public,anon,authenticated,service_role;
grant execute on function public.get_mdac_batch_memberships(),public.get_workers_health()
  to authenticated;
comment on function public.get_mdac_batch_memberships() is
  'Shared read for active Owner/Operator profiles, including unexpired review mode. No anonymous or service-only access.';
comment on function public.get_workers_health() is
  'Active business users read worker status; hostname only for full-access Owner. ONLINE/BUSY require a fresh heartbeat.';
