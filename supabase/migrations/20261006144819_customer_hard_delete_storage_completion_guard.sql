-- App backend is the sole migration owner. No App UI/worker change.
-- A client success flag is not proof that every file was removed. Recheck
-- the frozen manifest at BOTH lifecycle transitions. Never delete Storage
-- metadata here: physical object removal remains a Storage API operation.
create function private.guard_hard_delete_storage_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.assert_customer_delete_actor(auth.uid());
  if auth.uid() is distinct from new.created_by then
    raise exception 'delete job actor mismatch' using errcode = '42501';
  end if;
  if jsonb_typeof(new.storage_paths) is distinct from 'array' then
    raise exception 'invalid delete job storage manifest' using errcode = '22023';
  end if;
  if new.storage_object_count is distinct from jsonb_array_length(new.storage_paths)
     or exists (
       select 1 from jsonb_array_elements(new.storage_paths) p
       where jsonb_typeof(p) is distinct from 'object'
          or jsonb_typeof(p->'bucket') is distinct from 'string'
          or p->>'bucket' is distinct from 'passport-documents'
          or jsonb_typeof(p->'path') is distinct from 'string'
          or nullif(btrim(p->>'path'),'') is null
     ) then
    raise exception 'invalid or unauthorized delete job storage manifest'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(new.storage_paths) p
    join storage.objects o on o.bucket_id = p->>'bucket' and o.name = p->>'path'
  ) then
    raise exception 'Storage cleanup incomplete: manifest objects remain'
      using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function private.guard_hard_delete_storage_completion()
  from public,anon,authenticated,service_role;

create trigger customer_hard_delete_storage_completion_guard
  before update on private.customer_hard_delete_jobs
  for each row when (new.status in ('STORAGE_CLEANED','COMPLETED'))
  execute function private.guard_hard_delete_storage_completion();

comment on function private.guard_hard_delete_storage_completion() is
  'Fail closed on leftover Storage metadata/unsupported manifests at mark and complete. No Storage deletes, grants, or anonymous access.';
