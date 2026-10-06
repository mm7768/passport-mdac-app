-- Emergency containment ONLY. Do not remove the guard/reopen anonymous access.
-- This intentionally stops permanent deletion until a reviewed forward fix.
begin;
revoke all on function public.preview_customer_hard_delete(uuid[]),
 public.create_customer_hard_delete_job(uuid[]),
 public.mark_customer_hard_delete_storage_cleaned(uuid),
 public.fail_customer_hard_delete(uuid,text),
 public.complete_customer_hard_delete(uuid),
 private.preview_customer_hard_delete_internal(uuid[],uuid),
 private.create_customer_hard_delete_job_internal(uuid[],uuid),
 private.mark_customer_hard_delete_storage_cleaned_internal(uuid,uuid),
 private.fail_customer_hard_delete_internal(uuid,text,uuid),
 private.complete_customer_hard_delete_internal(uuid,uuid)
from public,anon,authenticated,service_role;
commit;
