-- Forward guard for deployed evidence-delete RPC and direct DELETE policies.
-- Apply after Website's review-only profile migration; production is not
-- modified by committing this file.
alter policy registration_checks_delete_active
  on public.registration_checks
  using (private.is_owner());
alter policy visit_pass_checks_delete_active
  on public.visit_pass_checks
  using (private.is_owner());

alter function public.delete_customer_human_evidence(uuid,text)
  set schema private;
alter function private.delete_customer_human_evidence(uuid,text)
  rename to delete_customer_human_evidence_before_owner_guard;
alter function private.delete_customer_human_evidence_before_owner_guard(uuid,text)
  set search_path = '';
revoke all on function private.delete_customer_human_evidence_before_owner_guard(uuid,text)
  from public,anon,authenticated,service_role;

create function public.delete_customer_human_evidence(
  p_check_id uuid,p_type text
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() is distinct from 'service_role' and not exists (
    select 1 from public.profiles p
    where p.id=auth.uid() and p.role='OWNER' and p.is_active
      and p.deleted_at is null and p.access_mode='FULL'
      and (p.access_expires_at is null or p.access_expires_at>now())
  ) then
    raise exception 'active full-access Owner required for evidence deletion'
      using errcode='42501';
  end if;
  return private.delete_customer_human_evidence_before_owner_guard(
    p_check_id,p_type);
end;
$$;
revoke all on function public.delete_customer_human_evidence(uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.delete_customer_human_evidence(uuid,text)
  to authenticated,service_role;
