CREATE OR REPLACE FUNCTION public.get_visit_pass_check_runtime_input(p_item_id uuid, p_worker_id text)
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
  from public.automation_items i
  join public.automation_batches b on b.id = i.batch_id
  join lateral (
    select p.pin_value
    from public.email_pin_records p
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
    from public.mdac_registrations m
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
