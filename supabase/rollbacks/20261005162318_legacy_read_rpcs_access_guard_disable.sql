-- Emergency containment, not a return to the anonymous legacy definitions.
-- Apply only if a compatibility failure requires disabling these two reads.
-- Forward fix and regrant authenticated after verification to restore service.
begin;
revoke all on function public.get_mdac_batch_memberships(),public.get_workers_health()
  from public,anon,authenticated,service_role;
commit;
