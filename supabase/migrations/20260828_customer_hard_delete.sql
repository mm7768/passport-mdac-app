-- Owner-triggered hard delete for customers with no in-progress workflow.
-- No scheduled cleanup is introduced. Storage paths are frozen per job and
-- must be deleted by the authenticated Owner before the DB transaction.

do $$
begin
  if not exists (
    select 1
      from pg_type
     where typname = 'customer_hard_delete_status'
       and typnamespace = 'public'::regnamespace
  ) then
    create type public.customer_hard_delete_status as enum (
      'REQUESTED',
      'STORAGE_CLEANED',
      'COMPLETED',
      'FAILED'
    );
  end if;
end
$$;

create table if not exists public.customer_hard_delete_jobs (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.profiles(id) on delete restrict,
  customer_ids uuid[] not null default '{}',
  storage_paths jsonb not null default '[]'::jsonb,
  customer_count integer not null default 0 check (customer_count >= 0),
  storage_object_count integer not null default 0 check (storage_object_count >= 0),
  status public.customer_hard_delete_status not null default 'REQUESTED',
  error_message text,
  created_at timestamptz not null default now(),
  storage_cleaned_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists customer_hard_delete_jobs_status_idx
  on public.customer_hard_delete_jobs (status, created_at desc);

create trigger customer_hard_delete_jobs_set_updated_at
before update on public.customer_hard_delete_jobs
for each row execute procedure public.set_updated_at();

alter table public.customer_hard_delete_jobs enable row level security;
revoke all on public.customer_hard_delete_jobs from public, anon, authenticated;

create or replace function private.customer_hard_delete_blockers(
  p_customer_id uuid
)
returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(jsonb_agg(reason order by reason), '[]'::jsonb)
    from (
      select 'AUTOMATION_ITEM:' || i.status::text as reason
        from public.automation_items i
       where i.customer_id = p_customer_id
         and i.status in ('QUEUED', 'CLAIMED', 'RUNNING', 'NEEDS_REVIEW')
      union all
      select 'AUTOMATION_BATCH:' || b.status::text as reason
        from public.automation_batches b
        join public.automation_items i on i.batch_id = b.id
       where i.customer_id = p_customer_id
         and b.status in ('QUEUED', 'CLAIMED', 'RUNNING', 'CANCEL_REQUESTED', 'NEEDS_REVIEW')
      union all
      select 'OCR_BATCH:' || b.status::text as reason
        from public.ocr_batches b
        join public.ocr_results r on r.batch_id = b.id
       where r.created_customer_id = p_customer_id
         and b.status in ('UPLOADED', 'PROCESSING', 'REVIEW_REQUIRED', 'READY_TO_CREATE')
      union all
      select 'OCR_RESULT:' || r.status::text as reason
        from public.ocr_results r
       where r.created_customer_id = p_customer_id
         and r.status in ('REVIEW_REQUIRED', 'READY_TO_CREATE')
      union all
      select 'MDAC_REGISTRATION:' || r.registration_status::text as reason
        from public.mdac_registrations r
       where r.customer_id = p_customer_id
         and r.registration_status in ('SUBMITTED', 'NEEDS_REVIEW', 'RESULT_UNKNOWN')
      union all
      select 'GMAIL_PIN:' || r.status::text as reason
        from public.email_pin_records r
       where r.customer_id = p_customer_id
         and r.status in ('NEEDS_REVIEW')
      union all
      select 'REGISTRATION_CHECK:' || r.result_status::text as reason
        from public.registration_checks r
       where r.customer_id = p_customer_id
         and r.result_status in ('UNPARSED', 'NEEDS_REVIEW')
      union all
      select 'VISIT_PASS_CHECK:' || r.result_status::text as reason
        from public.visit_pass_checks r
       where r.customer_id = p_customer_id
         and r.result_status in ('UNPARSED', 'NEEDS_REVIEW')
    ) blockers;
$$;

create or replace function private.customer_hard_delete_paths(
  p_customer_id uuid
)
returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'bucket', 'passport-documents',
        'path', clean_path
      ) order by clean_path
    ),
    '[]'::jsonb
  )
    from (
      select distinct trim(path) as clean_path
        from (
          select c.passport_image_path as path
            from public.customers c
           where c.id = p_customer_id
          union all
          select b.file_path as path
            from public.ocr_results r
            join public.ocr_batches b on b.id = r.batch_id
           where r.created_customer_id = p_customer_id
          union all
          select r.screenshot_path as path
            from public.mdac_registrations r
           where r.customer_id = p_customer_id
          union all
          select r.screenshot_path as path
            from public.registration_checks r
           where r.customer_id = p_customer_id
          union all
          select r.screenshot_path as path
            from public.visit_pass_checks r
           where r.customer_id = p_customer_id
        ) paths
       where path is not null
         and length(trim(path)) > 0
    ) unique_paths;
$$;

create or replace function private.customer_hard_delete_counts(
  p_customer_id uuid
)
returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select jsonb_build_object(
    'automation_items', (select count(*) from public.automation_items where customer_id = p_customer_id),
    'automation_batches', (select count(distinct i.batch_id) from public.automation_items i where i.customer_id = p_customer_id),
    'ocr_results', (select count(*) from public.ocr_results where created_customer_id = p_customer_id),
    'mdac_registrations', (select count(*) from public.mdac_registrations where customer_id = p_customer_id),
    'email_pin_records', (select count(*) from public.email_pin_records where customer_id = p_customer_id),
    'registration_checks', (select count(*) from public.registration_checks where customer_id = p_customer_id),
    'visit_pass_checks', (select count(*) from public.visit_pass_checks where customer_id = p_customer_id),
    'storage_objects', jsonb_array_length(private.customer_hard_delete_paths(p_customer_id))
  );
$$;

create or replace function public.preview_customer_hard_delete(
  p_customer_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_ids uuid[];
  v_rows jsonb;
begin
  if not private.is_active_user() or not private.is_owner() then
    raise exception 'owner permission required';
  end if;
  if p_customer_ids is null or coalesce(array_length(p_customer_ids, 1), 0) = 0 then
    raise exception 'customer_ids are required';
  end if;
  if array_length(p_customer_ids, 1) > 100 then
    raise exception 'at most 100 customers may be checked at once';
  end if;
  if exists (select 1 from unnest(p_customer_ids) as ids(id) where id is null) then
    raise exception 'customer_ids cannot contain null';
  end if;

  select array_agg(id order by id)
    into v_ids
    from (select distinct id from unnest(p_customer_ids) as ids(id)) unique_ids;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'customer_id', requested.id,
        'exists', c.id is not null,
        'can_delete', c.id is not null and jsonb_array_length(private.customer_hard_delete_blockers(c.id)) = 0,
        'blocked_reasons', case
          when c.id is null then jsonb_build_array('NOT_FOUND')
          else private.customer_hard_delete_blockers(c.id)
        end,
        'storage_object_count', case
          when c.id is null then 0
          else jsonb_array_length(private.customer_hard_delete_paths(c.id))
        end,
        'record_counts', case
          when c.id is null then '{}'::jsonb
          else private.customer_hard_delete_counts(c.id)
        end
      ) order by requested.id
    ),
    '[]'::jsonb
  )
    into v_rows
    from unnest(v_ids) as requested(id)
    left join public.customers c on c.id = requested.id;

  return jsonb_build_object(
    'requested_count', cardinality(v_ids),
    'rows', v_rows
  );
end;
$$;

create or replace function public.create_customer_hard_delete_job(
  p_customer_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_ids uuid[];
  v_id uuid;
  v_customer_ids uuid[] := '{}';
  v_blocked jsonb := '[]'::jsonb;
  v_blockers jsonb;
  v_job_id uuid;
  v_paths jsonb;
  v_storage_count integer;
begin
  if not private.is_active_user() or not private.is_owner() then
    raise exception 'owner permission required';
  end if;
  if p_customer_ids is null or coalesce(array_length(p_customer_ids, 1), 0) = 0 then
    raise exception 'customer_ids are required';
  end if;
  if array_length(p_customer_ids, 1) > 100 then
    raise exception 'at most 100 customers may be deleted at once';
  end if;
  if exists (select 1 from unnest(p_customer_ids) as ids(id) where id is null) then
    raise exception 'customer_ids cannot contain null';
  end if;

  select array_agg(id order by id)
    into v_ids
    from (select distinct id from unnest(p_customer_ids) as ids(id)) unique_ids;

  foreach v_id in array v_ids loop
    if not exists (select 1 from public.customers where id = v_id for update) then
      v_blocked := v_blocked || jsonb_build_array(
        jsonb_build_object(
          'customer_id', v_id,
          'reasons', jsonb_build_array('NOT_FOUND')
        )
      );
      continue;
    end if;

    v_blockers := private.customer_hard_delete_blockers(v_id);
    if jsonb_array_length(v_blockers) > 0 then
      v_blocked := v_blocked || jsonb_build_array(
        jsonb_build_object(
          'customer_id', v_id,
          'reasons', v_blockers
        )
      );
    else
      v_customer_ids := array_append(v_customer_ids, v_id);
    end if;
  end loop;

  if jsonb_array_length(v_blocked) > 0 then
    return jsonb_build_object(
      'job_id', null,
      'created', false,
      'eligible_customer_ids', to_jsonb(v_customer_ids),
      'blocked', v_blocked
    );
  end if;

  select coalesce(jsonb_agg(path_item order by path_item->>'path'), '[]'::jsonb)
    into v_paths
    from (
      select distinct jsonb_array_elements(
        private.customer_hard_delete_paths(selected.id)
      ) as path_item
        from unnest(v_customer_ids) as selected(id)
    ) paths;

  v_storage_count := jsonb_array_length(v_paths);

  insert into public.customer_hard_delete_jobs (
    requested_by,
    customer_ids,
    storage_paths,
    customer_count,
    storage_object_count,
    status
  ) values (
    auth.uid(),
    v_customer_ids,
    v_paths,
    cardinality(v_customer_ids),
    v_storage_count,
    'REQUESTED'
  ) returning id into v_job_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    auth.uid(),
    'CUSTOMER_HARD_DELETE_REQUESTED',
    'customer_hard_delete_job',
    v_job_id,
    jsonb_build_object(
      'customer_count', cardinality(v_customer_ids),
      'storage_object_count', v_storage_count,
      'storage_paths_returned', true
    )
  );

  return jsonb_build_object(
    'job_id', v_job_id,
    'created', true,
    'eligible_customer_ids', to_jsonb(v_customer_ids),
    'blocked', '[]'::jsonb,
    'storage_paths', v_paths,
    'storage_object_count', v_storage_count
  );
end;
$$;

create or replace function public.mark_customer_hard_delete_storage_cleaned(
  p_job_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_job public.customer_hard_delete_jobs;
begin
  if not private.is_active_user() or not private.is_owner() then
    raise exception 'owner permission required';
  end if;
  select * into v_job
    from public.customer_hard_delete_jobs
   where id = p_job_id
     and requested_by = auth.uid()
   for update;
  if not found then
    raise exception 'hard delete job not found';
  end if;
  if v_job.status <> 'REQUESTED' then
    raise exception 'hard delete job is not awaiting Storage cleanup';
  end if;

  update public.customer_hard_delete_jobs
     set status = 'STORAGE_CLEANED',
         storage_cleaned_at = now(),
         error_message = null
   where id = p_job_id;

  return jsonb_build_object(
    'job_id', p_job_id,
    'status', 'STORAGE_CLEANED',
    'customer_count', v_job.customer_count,
    'storage_object_count', v_job.storage_object_count
  );
end;
$$;

create or replace function public.fail_customer_hard_delete(
  p_job_id uuid,
  p_error_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_message text := left(nullif(trim(coalesce(p_error_message, '')), ''), 500);
begin
  if not private.is_active_user() or not private.is_owner() then
    raise exception 'owner permission required';
  end if;
  if v_message is null then
    v_message := 'Storage cleanup did not complete';
  end if;
  update public.customer_hard_delete_jobs
     set status = 'FAILED',
         error_message = v_message
   where id = p_job_id
     and requested_by = auth.uid()
     and status in ('REQUESTED', 'STORAGE_CLEANED');
  if not found then
    raise exception 'hard delete job cannot be marked failed';
  end if;
  return jsonb_build_object('job_id', p_job_id, 'status', 'FAILED');
end;
$$;

create or replace function public.complete_customer_hard_delete(
  p_job_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_job public.customer_hard_delete_jobs;
  v_id uuid;
  v_blockers jsonb;
  v_auto_batch_ids uuid[] := '{}';
  v_ocr_batch_ids uuid[] := '{}';
  v_customer_ids uuid[];
  v_customer_count integer;
begin
  if not private.is_active_user() or not private.is_owner() then
    raise exception 'owner permission required';
  end if;

  select * into v_job
    from public.customer_hard_delete_jobs
   where id = p_job_id
     and requested_by = auth.uid()
   for update;
  if not found then
    raise exception 'hard delete job not found';
  end if;
  if v_job.status = 'COMPLETED' then
    return jsonb_build_object(
      'job_id', p_job_id,
      'status', 'COMPLETED',
      'customer_count', v_job.customer_count,
      'storage_object_count', v_job.storage_object_count
    );
  end if;
  if v_job.status <> 'STORAGE_CLEANED' then
    raise exception 'Storage cleanup must be confirmed before database deletion';
  end if;

  v_customer_ids := v_job.customer_ids;
  foreach v_id in array v_customer_ids loop
    perform 1 from public.customers where id = v_id for update;
    if not found then
      raise exception 'customer disappeared before hard delete';
    end if;
    v_blockers := private.customer_hard_delete_blockers(v_id);
    if jsonb_array_length(v_blockers) > 0 then
      raise exception 'customer % has an in-progress task: %', v_id, v_blockers;
    end if;
  end loop;

  select coalesce(array_agg(distinct i.batch_id), '{}')
    into v_auto_batch_ids
    from public.automation_items i
   where i.customer_id = any(v_customer_ids);

  select coalesce(array_agg(distinct r.batch_id), '{}')
    into v_ocr_batch_ids
    from public.ocr_results r
   where r.created_customer_id = any(v_customer_ids);

  delete from public.mdac_registrations
   where customer_id = any(v_customer_ids);
  delete from public.email_pin_records
   where customer_id = any(v_customer_ids);
  delete from public.registration_checks
   where customer_id = any(v_customer_ids);
  delete from public.visit_pass_checks
   where customer_id = any(v_customer_ids);
  delete from public.ocr_results
   where created_customer_id = any(v_customer_ids);
  delete from public.automation_items
   where customer_id = any(v_customer_ids);

  if cardinality(v_auto_batch_ids) > 0 then
    delete from public.automation_batches b
     where b.id = any(v_auto_batch_ids)
       and not exists (
         select 1 from public.automation_items i where i.batch_id = b.id
       );
  end if;

  if cardinality(v_ocr_batch_ids) > 0 then
    delete from public.ocr_batches b
     where b.id = any(v_ocr_batch_ids)
       and not exists (
         select 1 from public.ocr_results r where r.batch_id = b.id
       );
  end if;

  delete from public.audit_logs
   where entity_id = any(v_customer_ids)
      or metadata->>'customer_id' in (
        select id::text from unnest(v_customer_ids) as selected(id)
      );

  delete from public.customers
   where id = any(v_customer_ids);
  get diagnostics v_customer_count = row_count;

  update public.customer_hard_delete_jobs
     set customer_ids = '{}',
         storage_paths = '[]'::jsonb,
         status = 'COMPLETED',
         completed_at = now(),
         error_message = null
   where id = p_job_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    auth.uid(),
    'CUSTOMER_HARD_DELETE_COMPLETED',
    'customer_hard_delete_job',
    p_job_id,
    jsonb_build_object(
      'customer_count', v_customer_count,
      'storage_object_count', v_job.storage_object_count,
      'customer_data_removed', true,
      'storage_cleanup_confirmed', true
    )
  );

  return jsonb_build_object(
    'job_id', p_job_id,
    'status', 'COMPLETED',
    'customer_count', v_customer_count,
    'storage_object_count', v_job.storage_object_count
  );
end;
$$;

revoke all on function public.preview_customer_hard_delete(uuid[]) from public, anon;
revoke all on function public.create_customer_hard_delete_job(uuid[]) from public, anon;
revoke all on function public.mark_customer_hard_delete_storage_cleaned(uuid) from public, anon;
revoke all on function public.fail_customer_hard_delete(uuid, text) from public, anon;
revoke all on function public.complete_customer_hard_delete(uuid) from public, anon;
grant execute on function public.preview_customer_hard_delete(uuid[]) to authenticated;
grant execute on function public.create_customer_hard_delete_job(uuid[]) to authenticated;
grant execute on function public.mark_customer_hard_delete_storage_cleaned(uuid) to authenticated;
grant execute on function public.fail_customer_hard_delete(uuid, text) to authenticated;
grant execute on function public.complete_customer_hard_delete(uuid) to authenticated;

comment on table public.customer_hard_delete_jobs is
  'Owner-triggered hard-delete jobs. No automatic purge. Completed jobs clear customer IDs and Storage paths.';
comment on function public.create_customer_hard_delete_job(uuid[]) is
  'Creates a hard-delete job only when every requested customer has no in-progress task.';
comment on function public.complete_customer_hard_delete(uuid) is
  'Owner-only final database purge after Storage cleanup; rechecks task eligibility under row locks.';
