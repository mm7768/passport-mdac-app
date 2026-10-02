-- Forward security fix for installations that already expose the legacy RPC.
-- Preserve its deployed behavior in private; enforce authorization at the
-- public boundary before any evidence, Storage, or task mutation can occur.
alter function public.rollback_customer_evidence(uuid[], text) set schema private;
alter function private.rollback_customer_evidence(uuid[], text)
  rename to rollback_customer_evidence_before_owner_guard;
alter function private.rollback_customer_evidence_before_owner_guard(uuid[], text)
  set search_path = '';
revoke all on function private.rollback_customer_evidence_before_owner_guard(uuid[], text)
  from public, anon, authenticated, service_role;

create function public.rollback_customer_evidence(
  p_customer_ids uuid[], p_target_status text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text := upper(trim(coalesce(p_target_status, '')));
begin
  if auth.role() = 'service_role' then
    return private.rollback_customer_evidence_before_owner_guard(
      p_customer_ids, p_target_status);
  end if;

  if auth.uid() is null or not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active and p.deleted_at is null
      and p.access_mode = 'FULL'
      and (p.access_expires_at is null or p.access_expires_at > now())
  ) then
    raise exception 'active full-access user required for customer status change'
      using errcode = '42501';
  end if;

  -- The legacy RPC deletes check evidence and Storage objects for these
  -- target states. Other states are non-destructive and remain available to
  -- full-access Operators through the existing App workflow.
  if v_status in (
    'PENDING', 'MDAC_REGISTERING', 'MDAC_REGISTERED', 'PIN_PENDING',
    'PIN_RECEIVED', 'VISIT_PASS_NOT_FOUND', 'ACTION_REQUIRED',
    'REGISTRATION_CHECKED'
  ) and not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'OWNER'
  ) then
    raise exception 'active full-access Owner required for evidence rollback'
      using errcode = '42501';
  end if;

  return private.rollback_customer_evidence_before_owner_guard(
    p_customer_ids, p_target_status);
end;
$$;

revoke all on function public.rollback_customer_evidence(uuid[], text)
  from public, anon, authenticated, service_role;
grant execute on function public.rollback_customer_evidence(uuid[], text)
  to authenticated, service_role;
