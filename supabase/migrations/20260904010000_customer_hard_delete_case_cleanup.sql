-- Keep permanent customer deletion compatible with the Customer / Passport / Case model.
-- Child rows are removed explicitly so the operation remains auditable and atomic.
create or replace function private.complete_customer_hard_delete_internal(
  p_job_id uuid, p_actor uuid
) returns jsonb
language plpgsql security definer
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  v_job private.customer_hard_delete_jobs; v_deleted int; v_batch_ids uuid[];
  v_deleted_ocr_batch_ids uuid[];
begin
  perform private.assert_customer_delete_actor(p_actor);
  select * into v_job from private.customer_hard_delete_jobs
    where id=p_job_id and created_by=p_actor for update;
  if not found then raise exception 'delete job not found'; end if;
  if v_job.status<>'STORAGE_CLEANED' then raise exception 'storage cleanup is not confirmed'; end if;

  perform 1 from public.customers c where c.id=any(v_job.customer_ids) for update;
  if exists(
    select 1 from public.automation_items i
    where i.customer_id=any(v_job.customer_ids)
      and i.status in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')
  ) then
    raise exception 'customer has active automation item';
  end if;

  select array_agg(distinct batch_id) into v_batch_ids
    from public.automation_items where customer_id=any(v_job.customer_ids);

  -- Results and tasks reference both customers and cases, so remove them first.
  delete from public.mdac_registrations where customer_id=any(v_job.customer_ids);
  delete from public.email_pin_records where customer_id=any(v_job.customer_ids);
  delete from public.registration_checks where customer_id=any(v_job.customer_ids);
  delete from public.visit_pass_checks where customer_id=any(v_job.customer_ids);
  delete from public.automation_items where customer_id=any(v_job.customer_ids);
  if v_batch_ids is not null then
    delete from public.automation_batches b
      where b.id=any(v_batch_ids)
        and not exists(select 1 from public.automation_items i where i.batch_id=b.id);
  end if;

  -- Remove linked OCR records, including legacy rows matched by normalized passport number.
  delete from public.ocr_results r
  where coalesce(r.created_customer_id=any(v_job.customer_ids),false)
    or (r.created_customer_id is null and exists (
      select 1 from public.customers c where c.id=any(v_job.customer_ids)
        and nullif(upper(regexp_replace(c.passport_number,'[^A-Z0-9]','','g')),'') is not null
        and nullif(upper(regexp_replace(r.extracted_data->>'passport_number','[^A-Z0-9]','','g')),'') is not null
        and upper(regexp_replace(c.passport_number,'[^A-Z0-9]','','g')) =
            upper(regexp_replace(r.extracted_data->>'passport_number','[^A-Z0-9]','','g'))
    ));
  if cardinality(v_job.ocr_batch_ids)>0 then
    with deleted as (
      delete from public.ocr_batches b
      where b.id=any(v_job.ocr_batch_ids)
        and not exists(select 1 from public.ocr_results r where r.batch_id=b.id)
      returning b.id
    ) select coalesce(array_agg(id),'{}'::uuid[])
      into v_deleted_ocr_batch_ids from deleted;
  else
    v_deleted_ocr_batch_ids := '{}'::uuid[];
  end if;

  -- New architecture dependencies: Case -> Passport -> Customer.
  delete from private.customer_mdac_profiles where customer_id=any(v_job.customer_ids);
  delete from public.customer_cases where customer_id=any(v_job.customer_ids);
  delete from public.passports where customer_id=any(v_job.customer_ids);
  delete from public.customers where id=any(v_job.customer_ids);
  get diagnostics v_deleted=row_count;
  if v_deleted<>v_job.customer_count then raise exception 'customer delete count mismatch'; end if;

  update private.customer_hard_delete_jobs
    set status='COMPLETED',completed_at=now(),updated_at=now()
    where id=p_job_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(p_actor,'HARD_DELETE_CUSTOMERS','customer_hard_delete_job',p_job_id,
    jsonb_build_object('customer_count',v_deleted,
      'storage_object_count',v_job.storage_object_count,
      'deleted_ocr_batch_ids',to_jsonb(v_deleted_ocr_batch_ids)));
  return jsonb_build_object('job_id',p_job_id,'status','COMPLETED',
    'customer_count',v_deleted,'storage_object_count',v_job.storage_object_count,
    'deleted_ocr_batch_ids',to_jsonb(v_deleted_ocr_batch_ids));
end $function$;

revoke all on function private.complete_customer_hard_delete_internal(uuid,uuid)
  from public,anon,authenticated,service_role;

