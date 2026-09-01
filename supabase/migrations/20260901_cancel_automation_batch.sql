-- Permanently delete queued, review-stage, or already-cancelled automation batches.
-- Customer and passport records are preserved. Related task results are deleted first.

create or replace function public.cancel_automation_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public, private, pg_temp
as $$
declare
  v_batch public.automation_batches;
  v_storage_paths jsonb := '[]'::jsonb;
  v_customer_ids uuid[];
  v_item_count integer := 0;
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;

  select *
    into v_batch
    from public.automation_batches
   where id = p_batch_id
   for update;

  if not found then
    raise exception 'automation batch not found';
  end if;

  if v_batch.status not in ('QUEUED', 'NEEDS_REVIEW', 'CANCELLED') then
    raise exception 'only queued, needs-review, or cancelled batches can be deleted';
  end if;

  select coalesce(array_agg(distinct i.customer_id), '{}'::uuid[]), count(*)
    into v_customer_ids, v_item_count
    from public.automation_items i
   where i.batch_id = p_batch_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'bucket', 'passport-documents',
        'path', m.screenshot_path
      )
    ) filter (
      where m.screenshot_path is not null
        and trim(m.screenshot_path) <> ''
    ),
    '[]'::jsonb
  )
    into v_storage_paths
    from public.mdac_registrations m
    join public.automation_items i on i.id = m.batch_item_id
   where i.batch_id = p_batch_id;

  delete from public.mdac_registrations m
   using public.automation_items i
   where m.batch_item_id = i.id
     and i.batch_id = p_batch_id;

  delete from public.email_pin_records e
   using public.automation_items i
   where e.batch_item_id = i.id
     and i.batch_id = p_batch_id;

  delete from public.registration_checks r
   using public.automation_items i
   where r.batch_item_id = i.id
     and i.batch_id = p_batch_id;

  delete from public.visit_pass_checks v
   using public.automation_items i
   where v.batch_item_id = i.id
     and i.batch_id = p_batch_id;

  delete from public.automation_items
   where batch_id = p_batch_id;

  delete from public.automation_batches
   where id = p_batch_id;

  update public.customers c
     set business_status = 'PENDING',
         updated_by = auth.uid(),
         updated_at = now()
   where c.id = any(v_customer_ids)
     and not exists (
       select 1
         from public.automation_items other_item
        where other_item.customer_id = c.id
          and other_item.status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW')
     );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    auth.uid(),
    'DELETE_CANCELLED_AUTOMATION_BATCH',
    'automation_batch',
    p_batch_id,
    jsonb_build_object(
      'previous_status', v_batch.status,
      'deleted_item_count', v_item_count
    )
  );

  return jsonb_build_object(
    'id', p_batch_id,
    'deleted', true,
    'deleted_item_count', v_item_count,
    'storage_paths', v_storage_paths
  );
end;
$$;

revoke execute on function public.cancel_automation_batch(uuid) from public, anon;
grant execute on function public.cancel_automation_batch(uuid) to authenticated;
