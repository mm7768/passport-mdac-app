-- Migration: Add service-role RPC for automated MDAC registration completion and fallback.
-- Allows the background Playwright Worker to write back SUCCEEDED, NEEDS_REVIEW, or FAILED.

create or replace function public.finish_mdac_registration_worker(
  p_item_id uuid,
  p_worker_id text,
  p_status text,
  p_registration_no text default null,
  p_screenshot_path text default null,
  p_raw_summary jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null
)
returns public.automation_items
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_now timestamptz := now();
  v_registration_no text := nullif(trim(coalesce(p_registration_no, '')), '');
  v_status text := upper(trim(coalesce(p_status, 'NEEDS_REVIEW')));
  v_summary jsonb;
begin
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_status not in ('SUCCEEDED', 'NEEDS_REVIEW', 'FAILED') then
    raise exception 'invalid worker completion status: %', v_status;
  end if;

  select *
    into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
   for update;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select *
    into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent MDAC batch not found';
  end if;

  if v_status = 'SUCCEEDED' then
    v_summary := coalesce(p_raw_summary, '{}'::jsonb)
      || jsonb_build_object(
        'worker_id', p_worker_id,
        'submitted', true,
        'result_confirmed', true,
        'auto_submitted', true,
        'completed_at', v_now
      );

    update public.automation_items
       set status = 'SUCCEEDED',
           finished_at = v_now,
           locked_by = null,
           locked_at = null,
           lease_expires_at = null,
           error_code = null,
           error_message = null,
           result_unknown = false
     where id = v_item.id
    returning * into v_item;

    insert into public.mdac_registrations (
      customer_id,
      batch_item_id,
      entry_date,
      exit_date,
      registration_no,
      registration_status,
      raw_summary,
      screenshot_path,
      submitted_at,
      result_confirmed_at
    ) values (
      v_item.customer_id,
      v_item.id,
      v_batch.entry_date,
      v_batch.exit_date,
      v_registration_no,
      'SUCCEEDED',
      v_summary,
      p_screenshot_path,
      v_now,
      v_now
    )
    on conflict (batch_item_id) do update set
      registration_no = coalesce(excluded.registration_no, mdac_registrations.registration_no),
      registration_status = 'SUCCEEDED',
      raw_summary = excluded.raw_summary,
      screenshot_path = coalesce(excluded.screenshot_path, mdac_registrations.screenshot_path),
      submitted_at = coalesce(mdac_registrations.submitted_at, v_now),
      result_confirmed_at = v_now,
      updated_at = v_now;

    update public.customers
       set business_status = 'MDAC_REGISTERED',
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;

    insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
    values (
      null,
      'MDAC_WORKER_AUTO_SUBMITTED',
      'automation_items',
      v_item.id,
      jsonb_build_object(
        'batch_id', v_batch.id,
        'customer_id', v_item.customer_id,
        'worker_id', p_worker_id,
        'registration_no', v_registration_no,
        'status', 'SUCCEEDED'
      )
    );

  elsif v_status = 'NEEDS_REVIEW' then
    v_summary := coalesce(p_raw_summary, '{}'::jsonb)
      || jsonb_build_object(
        'worker_id', p_worker_id,
        'submitted', false,
        'result_confirmed', false,
        'auto_submitted', false,
        'completed_at', v_now
      );

    update public.automation_items
       set status = 'NEEDS_REVIEW',
           finished_at = v_now,
           locked_by = null,
           locked_at = null,
           lease_expires_at = null,
           error_code = p_error_code,
           error_message = p_error_message,
           result_unknown = false
     where id = v_item.id
    returning * into v_item;

    insert into public.mdac_registrations (
      customer_id,
      batch_item_id,
      entry_date,
      exit_date,
      registration_no,
      registration_status,
      raw_summary,
      screenshot_path,
      submitted_at,
      result_confirmed_at
    ) values (
      v_item.customer_id,
      v_item.id,
      v_batch.entry_date,
      v_batch.exit_date,
      null,
      'NEEDS_REVIEW',
      v_summary,
      p_screenshot_path,
      null,
      null
    )
    on conflict (batch_item_id) do update set
      registration_status = 'NEEDS_REVIEW',
      raw_summary = excluded.raw_summary,
      screenshot_path = coalesce(excluded.screenshot_path, mdac_registrations.screenshot_path),
      submitted_at = null,
      result_confirmed_at = null,
      updated_at = v_now;

  else -- FAILED
    v_summary := coalesce(p_raw_summary, '{}'::jsonb)
      || jsonb_build_object(
        'worker_id', p_worker_id,
        'submitted', false,
        'result_confirmed', false,
        'completed_at', v_now
      );

    update public.automation_items
       set status = 'FAILED',
           finished_at = v_now,
           locked_by = null,
           locked_at = null,
           lease_expires_at = null,
           error_code = p_error_code,
           error_message = p_error_message,
           result_unknown = false
     where id = v_item.id
    returning * into v_item;

    insert into public.mdac_registrations (
      customer_id,
      batch_item_id,
      entry_date,
      exit_date,
      registration_no,
      registration_status,
      raw_summary,
      screenshot_path,
      submitted_at,
      result_confirmed_at
    ) values (
      v_item.customer_id,
      v_item.id,
      v_batch.entry_date,
      v_batch.exit_date,
      null,
      'FAILED',
      v_summary,
      p_screenshot_path,
      null,
      null
    )
    on conflict (batch_item_id) do update set
      registration_status = 'FAILED',
      raw_summary = excluded.raw_summary,
      screenshot_path = coalesce(excluded.screenshot_path, mdac_registrations.screenshot_path),
      updated_at = v_now;
  end if;

  -- Unlock batch if all items in batch are completed
  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where b.id = v_item.batch_id
     and not exists (
       select 1
         from public.automation_items i
        where i.batch_id = b.id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
     );

  return v_item;
end;
$$;

revoke execute on function public.finish_mdac_registration_worker(uuid, text, text, text, text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.finish_mdac_registration_worker(uuid, text, text, text, text, jsonb, text, text) to service_role;
