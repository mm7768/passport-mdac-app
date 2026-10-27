-- Disable ONLY the newly introduced manual-retry API. Keep attempt history.
-- No existing requeue RPC, state guard, RLS policy, Worker or business row changes.
begin;
revoke all on function public.preview_automation_manual_retry(uuid),
 public.request_automation_manual_retry(uuid,uuid,text,boolean)
 from public,anon,authenticated,service_role;
-- Deliberately retain restricted private history and request receipts. Removing
-- them would destroy prior uncertainty/attempt evidence. Their retention/purge
-- requires a separate, explicit customer-data deletion scope.
commit;
