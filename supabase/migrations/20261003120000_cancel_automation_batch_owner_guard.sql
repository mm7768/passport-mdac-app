-- Forward security fix for installations that already ran the 20260901 migration.
-- Keep the original deletion implementation private; the public RPC is now an
-- Owner-only authorization boundary. Do not roll this back to the old grants.
alter function public.cancel_automation_batch(uuid) set schema private;
alter function private.cancel_automation_batch(uuid)
  rename to cancel_automation_batch_before_owner_guard;
alter function private.cancel_automation_batch_before_owner_guard(uuid)
  set search_path = '';
revoke all on function private.cancel_automation_batch_before_owner_guard(uuid)
  from public, anon, authenticated, service_role;

create function public.cancel_automation_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'OWNER'
      and p.access_mode = 'FULL'
      and p.is_active
      and p.deleted_at is null
      and (p.access_expires_at is null or p.access_expires_at > now())
  ) then
    raise exception 'active full-access Owner required for permanent batch deletion'
      using errcode = '42501';
  end if;

  return private.cancel_automation_batch_before_owner_guard(p_batch_id);
end;
$$;

revoke all on function public.cancel_automation_batch(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.cancel_automation_batch(uuid) to authenticated;
