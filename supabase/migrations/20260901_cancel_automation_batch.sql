-- Allow authenticated active users to cancel queued or review-stage automation batches.
-- Cancellation preserves history, releases customer locks, and records an audit event.

create or replace function public.cancel_automation_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_batch public.automation_batches;
  v_success_count integer;
  v_failed_count integer;
  v_cancelled_count integer;
begin
  if not public.is_active_user() then
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

  if v_batch.status not in ('QUEUED', 'NEEDS_REVIEW') then
    raise exception 'only queued or needs-review batches can be cancelled';
  end if;

  update public.automation_items
     set status = 'CANCELLED',
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         finished_at = coalesce(finished_at, now()),
         error_code = 'CANCELLED_BY_USER',
         error_message = '用户从 App 取消任务',
         updated_at = now()
   where batch_id = p_batch_id
     and status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW');

  select
    count(*) filter (where status = 'SUCCEEDED'),
    count(*) filter (where status = 'FAILED'),
    count(*) filter (where status = 'CANCELLED')
    into v_success_count, v_failed_count, v_cancelled_count
    from public.automation_items
   where batch_id = p_batch_id;

  update public.automation_batches
     set status = 'CANCELLED',
         success_count = v_success_count,
         failed_count = v_failed_count,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         note = concat_ws('；', nullif(note, ''), '用户已取消'),
         updated_at = now()
   where id = p_batch_id;

  update public.customers c
     set business_status = 'PENDING',
         updated_by = auth.uid(),
         updated_at = now()
   where c.id in (
     select i.customer_id
       from public.automation_items i
      where i.batch_id = p_batch_id
   )
     and not exists (
       select 1
         from public.automation_items other_item
        where other_item.customer_id = c.id
          and other_item.batch_id <> p_batch_id
          and other_item.status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW')
   );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    auth.uid(),
    'CANCEL_AUTOMATION_BATCH',
    'automation_batch',
    p_batch_id,
    jsonb_build_object(
      'previous_status', v_batch.status,
      'cancelled_item_count', v_cancelled_count
    )
  );

  return jsonb_build_object(
    'id', p_batch_id,
    'status', 'CANCELLED',
    'cancelled_item_count', v_cancelled_count
  );
end;
$$;

revoke execute on function public.cancel_automation_batch(uuid) from public, anon;
grant execute on function public.cancel_automation_batch(uuid) to authenticated;
