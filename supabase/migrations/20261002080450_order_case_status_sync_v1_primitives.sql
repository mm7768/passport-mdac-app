-- Exact Order workflow synchronization for strict V1.2+ Automation Items.
-- Legacy Items with case_id = null remain Customer-status-only and never
-- guess an Order from customer_id.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

create or replace function private.sync_case_status_from_item_v1(
  p_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_item public.automation_items%rowtype;
  v_task public.automation_task_type;
  v_current public.case_status;
  v_target public.case_status;
  v_stage smallint;
  v_max_stage smallint;
  v_current_rank smallint;
  v_target_rank smallint;
  v_stage_success_rank smallint;
  v_should_advance boolean := false;
begin
  if p_item_id is null then
    raise exception 'item_id is required' using errcode = '22023';
  end if;

  select i.* into v_item
  from public.automation_items i
  where i.id = p_item_id;

  if not found then
    raise exception 'automation item not found: %', p_item_id
      using errcode = 'P0002';
  end if;

  -- Strict Order flow only. Legacy compatibility continues to update the
  -- Customer business_status inside the existing Worker finish RPCs.
  if v_item.case_id is null then
    return jsonb_build_object(
      'item_id', v_item.id,
      'mode', 'LEGACY',
      'changed', false
    );
  end if;

  select b.task_type into strict v_task
  from public.automation_batches b
  where b.id = v_item.batch_id;

  v_stage := case v_task
    when 'MDAC_REGISTRATION' then 1
    when 'GMAIL_PIN' then 2
    when 'REGISTRATION_CHECK' then 3
    when 'VISIT_PASS_CHECK' then 4
  end;

  v_target := case
    when v_item.status in ('FAILED', 'NEEDS_REVIEW')
      then 'ACTION_REQUIRED'::public.case_status
    when v_item.status = 'CANCELLED'
      then null
    when v_task = 'MDAC_REGISTRATION' and v_item.status = 'QUEUED'
      then 'READY_FOR_MDAC'::public.case_status
    when v_task = 'MDAC_REGISTRATION' and v_item.status in ('CLAIMED', 'RUNNING')
      then 'MDAC_PROCESSING'::public.case_status
    when v_task = 'MDAC_REGISTRATION' and v_item.status = 'SUCCEEDED'
      then 'MDAC_COMPLETED'::public.case_status
    when v_task = 'GMAIL_PIN' and v_item.status in ('QUEUED', 'CLAIMED', 'RUNNING')
      then 'WAITING_PIN'::public.case_status
    when v_task = 'GMAIL_PIN' and v_item.status = 'SUCCEEDED'
      then 'PIN_READY'::public.case_status
    when v_task = 'REGISTRATION_CHECK' and v_item.status in ('QUEUED', 'CLAIMED', 'RUNNING')
      then 'WAITING_REGISTRATION'::public.case_status
    when v_task = 'REGISTRATION_CHECK' and v_item.status = 'SUCCEEDED'
      then 'REGISTRATION_COMPLETED'::public.case_status
    when v_task = 'VISIT_PASS_CHECK' and v_item.status in ('QUEUED', 'CLAIMED', 'RUNNING')
      then 'WAITING_VISIT_PASS'::public.case_status
    when v_task = 'VISIT_PASS_CHECK' and v_item.status = 'SUCCEEDED'
      then 'VISIT_PASS_COMPLETED'::public.case_status
  end;

  if v_target is null then
    return jsonb_build_object(
      'item_id', v_item.id,
      'case_id', v_item.case_id,
      'mode', 'STRICT',
      'changed', false,
      'reason', 'NO_TARGET'
    );
  end if;

  -- Lock the exact Order after the Worker Item. Every strict Worker finish RPC
  -- already locks its Item first, so concurrent updates use the same order.
  select c.case_status into strict v_current
  from public.customer_cases c
  where c.id = v_item.case_id
    and c.customer_id = v_item.customer_id
  for update;

  select coalesce(max(case b.task_type
      when 'MDAC_REGISTRATION' then 1
      when 'GMAIL_PIN' then 2
      when 'REGISTRATION_CHECK' then 3
      when 'VISIT_PASS_CHECK' then 4
    end), v_stage)
    into v_max_stage
  from public.automation_items i
  join public.automation_batches b on b.id = i.batch_id
  where i.case_id = v_item.case_id;

  v_current_rank := case v_current
    when 'NEW' then 0
    when 'READY_FOR_MDAC' then 10
    when 'MDAC_PROCESSING' then 20
    when 'MDAC_COMPLETED' then 30
    when 'WAITING_PIN' then 40
    when 'PIN_READY' then 50
    when 'WAITING_REGISTRATION' then 60
    when 'REGISTRATION_COMPLETED' then 70
    when 'WAITING_VISIT_PASS' then 80
    when 'VISIT_PASS_COMPLETED' then 90
    when 'COMPLETED' then 100
    when 'ARCHIVED' then 110
    when 'CANCELLED' then 110
    when 'ACTION_REQUIRED' then null
  end;

  v_target_rank := case v_target
    when 'READY_FOR_MDAC' then 10
    when 'MDAC_PROCESSING' then 20
    when 'MDAC_COMPLETED' then 30
    when 'WAITING_PIN' then 40
    when 'PIN_READY' then 50
    when 'WAITING_REGISTRATION' then 60
    when 'REGISTRATION_COMPLETED' then 70
    when 'WAITING_VISIT_PASS' then 80
    when 'VISIT_PASS_COMPLETED' then 90
    else null
  end;

  v_stage_success_rank := case v_stage
    when 1 then 30
    when 2 then 50
    when 3 then 70
    when 4 then 90
  end;

  -- Overall terminal states are immutable here. ACTION_REQUIRED is stage-aware:
  -- a same/latest-stage retry may recover it, but an older stage can never
  -- overwrite a later-stage failure or success.
  if v_current in ('COMPLETED', 'ARCHIVED', 'CANCELLED') then
    v_should_advance := false;
  elsif v_target = 'ACTION_REQUIRED' then
    v_should_advance :=
      v_stage >= v_max_stage
      and v_current <> 'ACTION_REQUIRED'
      and v_current_rank < v_stage_success_rank;
  elsif v_current = 'ACTION_REQUIRED' then
    v_should_advance := v_stage >= v_max_stage;
  else
    v_should_advance := v_target_rank > v_current_rank;
  end if;

  if v_should_advance then
    update public.customer_cases
       set case_status = v_target,
           updated_at = clock_timestamp()
     where id = v_item.case_id
       and customer_id = v_item.customer_id;

    insert into public.audit_logs (
      actor_id,
      action,
      entity_type,
      entity_id,
      metadata
    ) values (
      null,
      'ORDER_WORKFLOW_STATUS_SYNC',
      'ORDER',
      v_item.case_id,
      jsonb_build_object(
        'automation_item_id', v_item.id,
        'automation_batch_id', v_item.batch_id,
        'task_type', v_task,
        'item_status', v_item.status,
        'previous_case_status', v_current,
        'next_case_status', v_target,
        'stage', v_stage,
        'max_case_stage', v_max_stage
      )
    );
  end if;

  return jsonb_build_object(
    'item_id', v_item.id,
    'case_id', v_item.case_id,
    'mode', 'STRICT',
    'task_type', v_task,
    'item_status', v_item.status,
    'previous_case_status', v_current,
    'target_case_status', v_target,
    'changed', v_should_advance
  );
end
$function$;

revoke all on function private.sync_case_status_from_item_v1(uuid)
  from public, anon, authenticated, service_role;

create or replace function private.sync_case_status_from_automation_item_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform private.sync_case_status_from_item_v1(new.id);
  return new;
end
$function$;

revoke all on function private.sync_case_status_from_automation_item_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists automation_items_sync_order_status_v1
  on public.automation_items;

create trigger automation_items_sync_order_status_v1
after insert or update of status, case_id, batch_id
on public.automation_items
for each row
execute function private.sync_case_status_from_automation_item_v1();

comment on trigger automation_items_sync_order_status_v1
  on public.automation_items is
  'Advances the exact customer_cases row identified by automation_items.case_id; never infers by customer_id.';

commit;
