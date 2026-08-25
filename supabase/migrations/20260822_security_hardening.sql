-- Keep internal SECURITY DEFINER helpers outside the exposed public API schema.
create schema if not exists private;

alter function public.current_profile() set schema private;
alter function public.is_active_user() set schema private;
alter function public.is_owner() set schema private;
alter function public.handle_new_user() set schema private;
alter function public.sync_automation_batch_counts() set schema private;

revoke all on schema private from public, anon, authenticated;
revoke all on function private.current_profile() from public, anon, authenticated;
revoke all on function private.is_active_user() from public, anon, authenticated;
revoke all on function private.is_owner() from public, anon, authenticated;
revoke all on function private.handle_new_user() from public, anon, authenticated;
revoke all on function private.sync_automation_batch_counts() from public, anon, authenticated;

grant usage on schema private to postgres, service_role;
grant execute on function private.current_profile() to postgres, service_role;
grant execute on function private.is_active_user() to postgres, service_role;
grant execute on function private.is_owner() to postgres, service_role;
grant execute on function private.handle_new_user() to postgres, service_role;
grant execute on function private.sync_automation_batch_counts() to postgres, service_role;

comment on schema private is 'Internal helper functions only; do not expose through the Data API.';
