-- The public SECURITY INVOKER wrapper runs as the signed-in caller, so that
-- caller needs EXECUTE on the private implementation. The implementation
-- validates auth.uid() and the delete-job owner before changing any data.
revoke all on function private.complete_customer_hard_delete_internal(uuid,uuid)
  from public,anon,service_role;
grant execute on function private.complete_customer_hard_delete_internal(uuid,uuid)
  to authenticated;

