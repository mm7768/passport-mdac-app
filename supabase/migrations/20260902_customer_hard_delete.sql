-- Complete two-phase customer hard deletion with Storage cleanup and active-task protection.
-- Privileged deletes stay in private security-definer functions; public RPC wrappers remain security invoker.

create table if not exists private.customer_hard_delete_jobs (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null,
  customer_ids uuid[] not null,
  storage_paths jsonb not null default '[]'::jsonb,
  customer_count integer not null default 0,
  storage_object_count integer not null default 0,
  status text not null check (status in ('AWAITING_STORAGE','STORAGE_CLEANED','COMPLETED','FAILED')),
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
alter table private.customer_hard_delete_jobs enable row level security;

create or replace function private.assert_customer_delete_actor(p_actor uuid)
returns void language plpgsql security definer
set search_path=public,private,pg_temp as $$
begin
  if p_actor is null or p_actor is distinct from auth.uid() or not private.is_active_user() then
    raise exception 'active user required';
  end if;
end $$;

create or replace function private.preview_customer_hard_delete_internal(p_customer_ids uuid[], p_actor uuid)
returns jsonb language plpgsql security definer
set search_path=public,private,pg_temp as $$
declare v_rows jsonb;
begin
  perform private.assert_customer_delete_actor(p_actor);
  if p_customer_ids is null or cardinality(p_customer_ids)=0 then raise exception 'at least one customer required'; end if;
  if cardinality(p_customer_ids)>100 then raise exception 'maximum 100 customers'; end if;

  with requested as (
    select distinct id from unnest(p_customer_ids) id
  ), details as (
    select r.id customer_id, c.id is not null as exists,
      coalesce((select jsonb_agg(distinct 'AUTOMATION_ITEM:'||i.status::text)
                from public.automation_items i
                where i.customer_id=r.id and i.status in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')), '[]'::jsonb) blockers,
      jsonb_build_object(
        'automation_items',(select count(*) from public.automation_items i where i.customer_id=r.id),
        'email_pin_records',(select count(*) from public.email_pin_records e where e.customer_id=r.id),
        'mdac_registrations',(select count(*) from public.mdac_registrations m where m.customer_id=r.id),
        'registration_checks',(select count(*) from public.registration_checks x where x.customer_id=r.id),
        'visit_pass_checks',(select count(*) from public.visit_pass_checks v where v.customer_id=r.id),
        'ocr_results',(select count(*) from public.ocr_results o where o.created_customer_id=r.id)
      ) record_counts,
      ((case when nullif(trim(c.passport_image_path),'') is null then 0 else 1 end)
       +(select count(*) from public.mdac_registrations m where m.customer_id=r.id and nullif(trim(m.screenshot_path),'') is not null)
       +(select count(*) from public.registration_checks x where x.customer_id=r.id and nullif(trim(x.screenshot_path),'') is not null)
       +(select count(*) from public.visit_pass_checks v where v.customer_id=r.id and nullif(trim(v.screenshot_path),'') is not null))::int storage_count
    from requested r left join public.customers c on c.id=r.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_id',customer_id,'exists',exists,
    'can_delete',exists and jsonb_array_length(blockers)=0,
    'blocked_reasons',case when not exists then '["NOT_FOUND"]'::jsonb else blockers end,
    'storage_object_count',storage_count,'record_counts',record_counts
  ) order by customer_id), '[]'::jsonb) into v_rows from details;
  return jsonb_build_object('rows',v_rows);
end $$;

create or replace function private.create_customer_hard_delete_job_internal(p_customer_ids uuid[], p_actor uuid)
returns jsonb language plpgsql security definer
set search_path=public,private,pg_temp as $$
declare v_preview jsonb; v_blocked jsonb; v_paths jsonb; v_job uuid; v_ids uuid[];
begin
  perform private.assert_customer_delete_actor(p_actor);
  select array_agg(distinct id) into v_ids from unnest(p_customer_ids) id;
  v_preview:=private.preview_customer_hard_delete_internal(v_ids,p_actor);
  select coalesce(jsonb_agg(jsonb_build_object('customer_id',x->>'customer_id','reasons',x->'blocked_reasons')),'[]'::jsonb)
    into v_blocked from jsonb_array_elements(v_preview->'rows') x where not coalesce((x->>'can_delete')::boolean,false);
  if jsonb_array_length(v_blocked)>0 then return jsonb_build_object('created',false,'blocked',v_blocked); end if;

  with paths as (
    select 'passport-documents' bucket, c.passport_image_path path from public.customers c where c.id=any(v_ids)
    union select 'passport-documents',m.screenshot_path from public.mdac_registrations m where m.customer_id=any(v_ids)
    union select 'passport-documents',r.screenshot_path from public.registration_checks r where r.customer_id=any(v_ids)
    union select 'passport-documents',v.screenshot_path from public.visit_pass_checks v where v.customer_id=any(v_ids)
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket,'path',path)),'[]'::jsonb)
      into v_paths from (select distinct bucket,path from paths where nullif(trim(path),'') is not null) q;

  insert into private.customer_hard_delete_jobs(created_by,customer_ids,storage_paths,customer_count,storage_object_count,status)
  values(p_actor,v_ids,v_paths,cardinality(v_ids),jsonb_array_length(v_paths),'AWAITING_STORAGE') returning id into v_job;
  return jsonb_build_object('created',true,'job_id',v_job,'blocked','[]'::jsonb,'storage_paths',v_paths);
end $$;

create or replace function private.mark_customer_hard_delete_storage_cleaned_internal(p_job_id uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_job private.customer_hard_delete_jobs;
begin
  perform private.assert_customer_delete_actor(p_actor);
  select * into v_job from private.customer_hard_delete_jobs where id=p_job_id and created_by=p_actor for update;
  if not found then raise exception 'delete job not found'; end if;
  if v_job.status<>'AWAITING_STORAGE' then raise exception 'delete job is not awaiting storage cleanup'; end if;
  update private.customer_hard_delete_jobs set status='STORAGE_CLEANED',updated_at=now() where id=p_job_id;
  return jsonb_build_object('job_id',p_job_id,'status','STORAGE_CLEANED');
end $$;

create or replace function private.fail_customer_hard_delete_internal(p_job_id uuid,p_error_message text,p_actor uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
  perform private.assert_customer_delete_actor(p_actor);
  update private.customer_hard_delete_jobs set status='FAILED',error_message=left(coalesce(p_error_message,'unknown failure'),2000),updated_at=now()
   where id=p_job_id and created_by=p_actor and status<>'COMPLETED';
  if not found then raise exception 'delete job not found or already completed'; end if;
  return jsonb_build_object('job_id',p_job_id,'status','FAILED');
end $$;

create or replace function private.complete_customer_hard_delete_internal(p_job_id uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_job private.customer_hard_delete_jobs; v_deleted int; v_batch_ids uuid[];
begin
  perform private.assert_customer_delete_actor(p_actor);
  select * into v_job from private.customer_hard_delete_jobs where id=p_job_id and created_by=p_actor for update;
  if not found then raise exception 'delete job not found'; end if;
  if v_job.status<>'STORAGE_CLEANED' then raise exception 'storage cleanup is not confirmed'; end if;
  perform 1 from public.customers c where c.id=any(v_job.customer_ids) for update;
  if exists(select 1 from public.automation_items i where i.customer_id=any(v_job.customer_ids) and i.status in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')) then
    raise exception 'customer has active automation item';
  end if;
  select array_agg(distinct batch_id) into v_batch_ids from public.automation_items where customer_id=any(v_job.customer_ids);
  delete from public.mdac_registrations where customer_id=any(v_job.customer_ids);
  delete from public.email_pin_records where customer_id=any(v_job.customer_ids);
  delete from public.registration_checks where customer_id=any(v_job.customer_ids);
  delete from public.visit_pass_checks where customer_id=any(v_job.customer_ids);
  delete from public.automation_items where customer_id=any(v_job.customer_ids);
  if v_batch_ids is not null then
    delete from public.automation_batches b where b.id=any(v_batch_ids) and not exists(select 1 from public.automation_items i where i.batch_id=b.id);
  end if;
  update public.ocr_results set created_customer_id=null where created_customer_id=any(v_job.customer_ids);
  delete from public.customers where id=any(v_job.customer_ids);
  get diagnostics v_deleted=row_count;
  if v_deleted<>v_job.customer_count then raise exception 'customer delete count mismatch'; end if;
  update private.customer_hard_delete_jobs set status='COMPLETED',completed_at=now(),updated_at=now() where id=p_job_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(p_actor,'HARD_DELETE_CUSTOMERS','customer_hard_delete_job',p_job_id,
    jsonb_build_object('customer_count',v_deleted,'storage_object_count',v_job.storage_object_count));
  return jsonb_build_object('job_id',p_job_id,'status','COMPLETED','customer_count',v_deleted,'storage_object_count',v_job.storage_object_count);
end $$;

create or replace function public.preview_customer_hard_delete(p_customer_ids uuid[]) returns jsonb
language sql security invoker set search_path=public,private,pg_temp as $$
 select private.preview_customer_hard_delete_internal(p_customer_ids,auth.uid()) $$;
create or replace function public.create_customer_hard_delete_job(p_customer_ids uuid[]) returns jsonb
language sql security invoker set search_path=public,private,pg_temp as $$
 select private.create_customer_hard_delete_job_internal(p_customer_ids,auth.uid()) $$;
create or replace function public.mark_customer_hard_delete_storage_cleaned(p_job_id uuid) returns jsonb
language sql security invoker set search_path=public,private,pg_temp as $$
 select private.mark_customer_hard_delete_storage_cleaned_internal(p_job_id,auth.uid()) $$;
create or replace function public.fail_customer_hard_delete(p_job_id uuid,p_error_message text) returns jsonb
language sql security invoker set search_path=public,private,pg_temp as $$
 select private.fail_customer_hard_delete_internal(p_job_id,p_error_message,auth.uid()) $$;
create or replace function public.complete_customer_hard_delete(p_job_id uuid) returns jsonb
language sql security invoker set search_path=public,private,pg_temp as $$
 select private.complete_customer_hard_delete_internal(p_job_id,auth.uid()) $$;

revoke all on table private.customer_hard_delete_jobs from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.preview_customer_hard_delete_internal(uuid[],uuid) to authenticated;
grant execute on function private.create_customer_hard_delete_job_internal(uuid[],uuid) to authenticated;
grant execute on function private.mark_customer_hard_delete_storage_cleaned_internal(uuid,uuid) to authenticated;
grant execute on function private.fail_customer_hard_delete_internal(uuid,text,uuid) to authenticated;
grant execute on function private.complete_customer_hard_delete_internal(uuid,uuid) to authenticated;
revoke execute on function public.preview_customer_hard_delete(uuid[]) from public,anon;
revoke execute on function public.create_customer_hard_delete_job(uuid[]) from public,anon;
revoke execute on function public.mark_customer_hard_delete_storage_cleaned(uuid) from public,anon;
revoke execute on function public.fail_customer_hard_delete(uuid,text) from public,anon;
revoke execute on function public.complete_customer_hard_delete(uuid) from public,anon;
grant execute on function public.preview_customer_hard_delete(uuid[]) to authenticated;
grant execute on function public.create_customer_hard_delete_job(uuid[]) to authenticated;
grant execute on function public.mark_customer_hard_delete_storage_cleaned(uuid) to authenticated;
grant execute on function public.fail_customer_hard_delete(uuid,text) to authenticated;
grant execute on function public.complete_customer_hard_delete(uuid) to authenticated;

notify pgrst, 'reload schema';
