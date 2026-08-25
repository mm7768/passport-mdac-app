-- RLS policies execute these private helpers on behalf of authenticated users.
-- The private schema remains outside the exposed Data API schema.
grant usage on schema private to authenticated;
grant execute on function private.current_profile() to authenticated;
grant execute on function private.is_active_user() to authenticated;
grant execute on function private.is_owner() to authenticated;
revoke execute on function private.handle_new_user() from public, anon, authenticated;
revoke execute on function private.sync_automation_batch_counts() from public, anon, authenticated;
