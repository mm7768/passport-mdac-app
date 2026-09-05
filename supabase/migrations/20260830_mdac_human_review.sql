-- Human-in-the-loop completion for MDAC registrations.
--
-- The Railway worker remains FILL_PREVIEW only. These RPCs are called by an
-- authenticated App user after the user manually completes the official MDAC
-- CAPTCHA/slider inside the App WebView and explicitly confirms submission.
-- No CAPTCHA-solving logic or privileged service-role secret is exposed here.

-- Preserve NEEDS_REVIEW at batch level when every non-terminal item is waiting
-- for a person. The previous trigger treated that state as QUEUED, which could
-- make a partially completed human-review batch appear to have returned to the
-- worker queue.
create or replace function private.sync_automation_batch_counts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_batch uuid;
  total_items integer;
  succeeded_items integer;
  failed_items integer;
  running_items integer;
  queued_items integer;
  review_items integer;
  next_status public.automation_status;
begin
  target_batch := coalesce(new.batch_id, old.batch_id);

  select count(*)::integer,
         count(*) filter (where status = 'SUCCEEDED')::integer,
         count(*) filter (where status = 'FAILED')::integer,
         count(*) filter (where status in ('CLAIMED', 'RUNNING'))::integer,
         count(*) filter (where status = 'QUEUED')::integer,
         count(*) filter (where status = 'NEEDS_REVIEW')::integer
    into total_items,
         succeeded_items,
         failed_items,
         running_items,
         queued_items,
         review_items
    from public.automation_items
   where batch_id = target_batch;

  select status
    into next_status
    from public.automation_batches
   where id = target_batch;

  if total_items > 0 then
    if running_items > 0 then
      next_status := 'RUNNING';
    elsif queued_items > 0 then
      next_status := 'QUEUED';
    elsif review_items > 0 then
      next_status := 'NEEDS_REVIEW';
    elsif failed_items = total_items then
      next_status := 'FAILED';
    elsif succeeded_items = total_items then
      next_status := 'SUCCEEDED';
    elsif succeeded_items + failed_items = total_items then
      next_status := 'PARTIAL_SUCCESS';
    end if;
  end if;

  update public.automation_batches
     set total_count = total_items,
         success_count = succeeded_items,
         failed_count = failed_items,
         status = next_status,
         updated_at = now()
   where id = target_batch;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Record that the user explicitly requested the official page submit action.
-- The item intentionally remains NEEDS_REVIEW until the official result is
-- confirmed. This prevents a click from being mistaken for a successful MDAC.
create or replace function public.mark_mdac_human_submitted(
  p_item_id uuid,
  p_evidence jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, private
as $$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_registration public.mdac_registrations;
  v_now timestamptz := now();
begin
  if auth.uid() is null or not private.is_active_user() then
    raise exception 'active authenticated user required';
  end if;
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;

  select i.*
    into v_item
    from public.automation_items i
   where i.id = p_item_id
   for update;

  if not found then
    raise exception 'MDAC item not found';
  end if;

  select b.*
    into v_batch
    from public.automation_batches b
   where b.id = v_item.batch_id
     and b.task_type = 'MDAC_REGISTRATION';

  if not found then
    raise exception 'item is not part of an MDAC registration batch';
  end if;
  if v_item.status <> 'NEEDS_REVIEW' then
    raise exception 'MDAC item is not waiting for human review';
  end if;

  select r.*
    into v_registration
    from public.mdac_registrations r
   where r.batch_item_id = v_item.id
   for update;

  if not found then
    raise exception 'MDAC preview registration record not found';
  end if;

  if v_registration.registration_status not in ('NEEDS_REVIEW', 'SUBMITTED') then
    raise exception 'MDAC registration is not eligible for human submission';
  end if;

  update public.mdac_registrations
     set registration_status = 'SUBMITTED',
         submitted_at = coalesce(submitted_at, v_now),
         result_confirmed_at = null,
         raw_summary = coalesce(raw_summary, '{}'::jsonb)
           || coalesce(p_evidence, '{}'::jsonb)
           || jsonb_build_object(
                'human_in_loop', true,
                'human_submit_requested', true,
                'human_submit_actor_id', auth.uid(),
                'human_submit_recorded_at', v_now,
                'result_confirmed', false
              )
   where id = v_registration.id;

  update public.automation_items
     set result_unknown = false,
         error_code = null,
         error_message = null,
         finished_at = v_now
   where id = v_item.id;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'MDAC_HUMAN_SUBMIT_REQUESTED',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_item.batch_id,
      'customer_id', v_item.customer_id,
      'submitted', true,
      'result_confirmed', false
    )
  );

  return jsonb_build_object(
    'item_id', v_item.id,
    'batch_id', v_item.batch_id,
    'registration_status', 'SUBMITTED',
    'submitted_at', v_now,
    'result_confirmed', false
  );
end;
$$;

-- Finalize success only after the official result page is visible and the
-- signed-in user explicitly confirms that it reports a successful registration.
create or replace function public.confirm_mdac_human_success(
  p_item_id uuid,
  p_registration_no text default null,
  p_evidence jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, private
as $$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_registration public.mdac_registrations;
  v_now timestamptz := now();
  v_registration_no text := nullif(trim(coalesce(p_registration_no, '')), '');
begin
  if auth.uid() is null or not private.is_active_user() then
    raise exception 'active authenticated user required';
  end if;
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;

  select i.*
    into v_item
    from public.automation_items i
   where i.id = p_item_id
   for update;

  if not found then
    raise exception 'MDAC item not found';
  end if;

  select b.*
    into v_batch
    from public.automation_batches b
   where b.id = v_item.batch_id
     and b.task_type = 'MDAC_REGISTRATION';

  if not found then
    raise exception 'item is not part of an MDAC registration batch';
  end if;
  if v_item.status <> 'NEEDS_REVIEW' then
    raise exception 'MDAC item is not waiting for human review';
  end if;

  select r.*
    into v_registration
    from public.mdac_registrations r
   where r.batch_item_id = v_item.id
   for update;

  if not found then
    raise exception 'MDAC registration record not found';
  end if;
  if v_registration.registration_status <> 'SUBMITTED' then
    raise exception 'MDAC submission must be recorded before success confirmation';
  end if;

  update public.mdac_registrations
     set registration_no = coalesce(v_registration_no, registration_no),
         registration_status = 'SUCCEEDED',
         submitted_at = coalesce(submitted_at, v_now),
         result_confirmed_at = v_now,
         raw_summary = coalesce(raw_summary, '{}'::jsonb)
           || coalesce(p_evidence, '{}'::jsonb)
           || jsonb_build_object(
                'human_in_loop', true,
                'submitted', true,
                'result_confirmed', true,
                'human_confirmed_by', auth.uid(),
                'human_confirmed_at', v_now
              )
   where id = v_registration.id;

  -- Updating the item fires private.sync_automation_batch_counts(), so the
  -- parent batch automatically becomes SUCCEEDED / PARTIAL_SUCCESS /
  -- NEEDS_REVIEW according to its remaining items.
  update public.automation_items
     set status = 'SUCCEEDED',
         result_unknown = false,
         error_code = null,
         error_message = null,
         finished_at = v_now,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where id = v_item.id;

  update public.customers
     set business_status = 'MDAC_REGISTERED',
         updated_by = auth.uid()
   where id = v_item.customer_id
     and deleted_at is null;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'MDAC_HUMAN_CONFIRMED',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_item.batch_id,
      'customer_id', v_item.customer_id,
      'registration_no_present', v_registration_no is not null,
      'submitted', true,
      'result_confirmed', true
    )
  );

  select b.* into v_batch
    from public.automation_batches b
   where b.id = v_item.batch_id;

  return jsonb_build_object(
    'item_id', v_item.id,
    'batch_id', v_item.batch_id,
    'item_status', 'SUCCEEDED',
    'batch_status', v_batch.status,
    'success_count', v_batch.success_count,
    'failed_count', v_batch.failed_count,
    'registration_status', 'SUCCEEDED'
  );
end;
$$;

-- A submit click may succeed while the response is lost or ambiguous. Preserve
-- that uncertainty so the App never offers a blind second submission as if
-- nothing happened.
create or replace function public.mark_mdac_human_result_unknown(
  p_item_id uuid,
  p_evidence jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, private
as $$
declare
  v_item public.automation_items;
  v_registration public.mdac_registrations;
  v_now timestamptz := now();
begin
  if auth.uid() is null or not private.is_active_user() then
    raise exception 'active authenticated user required';
  end if;
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;

  select i.*
    into v_item
    from public.automation_items i
    join public.automation_batches b on b.id = i.batch_id
   where i.id = p_item_id
     and b.task_type = 'MDAC_REGISTRATION'
   for update of i;

  if not found or v_item.status <> 'NEEDS_REVIEW' then
    raise exception 'MDAC item is not waiting for human review';
  end if;

  select r.*
    into v_registration
    from public.mdac_registrations r
   where r.batch_item_id = v_item.id
   for update;

  if not found or v_registration.registration_status <> 'SUBMITTED' then
    raise exception 'MDAC submission has not been recorded';
  end if;

  update public.mdac_registrations
     set registration_status = 'RESULT_UNKNOWN',
         submitted_at = coalesce(submitted_at, v_now),
         result_confirmed_at = null,
         raw_summary = coalesce(raw_summary, '{}'::jsonb)
           || coalesce(p_evidence, '{}'::jsonb)
           || jsonb_build_object(
                'human_in_loop', true,
                'submitted', true,
                'result_confirmed', false,
                'result_unknown', true,
                'human_marked_unknown_by', auth.uid(),
                'human_marked_unknown_at', v_now
              )
   where id = v_registration.id;

  update public.automation_items
     set status = 'NEEDS_REVIEW',
         result_unknown = true,
         error_code = 'HUMAN_RESULT_UNKNOWN',
         error_message = 'Official MDAC submit was attempted but the result was not confirmed',
         finished_at = v_now
   where id = v_item.id;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'MDAC_HUMAN_RESULT_UNKNOWN',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_item.batch_id,
      'customer_id', v_item.customer_id,
      'submitted', true,
      'result_confirmed', false,
      'result_unknown', true
    )
  );

  return jsonb_build_object(
    'item_id', v_item.id,
    'batch_id', v_item.batch_id,
    'item_status', 'NEEDS_REVIEW',
    'registration_status', 'RESULT_UNKNOWN',
    'result_unknown', true
  );
end;
$$;

revoke execute on function public.mark_mdac_human_submitted(uuid, jsonb) from public, anon;
revoke execute on function public.confirm_mdac_human_success(uuid, text, jsonb) from public, anon;
revoke execute on function public.mark_mdac_human_result_unknown(uuid, jsonb) from public, anon;

grant execute on function public.mark_mdac_human_submitted(uuid, jsonb) to authenticated;
grant execute on function public.confirm_mdac_human_success(uuid, text, jsonb) to authenticated;
grant execute on function public.mark_mdac_human_result_unknown(uuid, jsonb) to authenticated;
