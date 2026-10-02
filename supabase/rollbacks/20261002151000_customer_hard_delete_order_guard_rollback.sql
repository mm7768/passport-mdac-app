-- Only use in coordinated rollback. This restores the older, less restrictive
-- App purge behavior; keep the App permanently-delete UI disabled until fixed.
begin;
do $$ begin
  if exists (select 1 from private.customer_hard_delete_jobs
    where status in ('AWAITING_STORAGE','STORAGE_CLEANED')) then
    raise exception 'Pending hard-delete job: rollback refused';
  end if;
end $$;
drop trigger customer_hard_delete_job_eligibility on private.customer_hard_delete_jobs;
drop trigger pending_hard_delete_case_guard on public.customer_cases;
drop trigger pending_hard_delete_passport_guard on public.passports;
drop trigger pending_hard_delete_item_guard on public.automation_items;
drop trigger pending_hard_delete_mdac_guard on public.mdac_registrations;
drop trigger pending_hard_delete_pin_guard on public.email_pin_records;
drop trigger pending_hard_delete_registration_guard on public.registration_checks;
drop trigger pending_hard_delete_visit_pass_guard on public.visit_pass_checks;
drop trigger pending_hard_delete_ocr_guard on public.ocr_results;
drop function private.assert_hard_delete_job_eligible();
drop function private.guard_pending_hard_delete_reference();
drop function private.guard_pending_hard_delete_work();
drop function private.preview_customer_hard_delete_internal(uuid[],uuid);
drop function private.complete_customer_hard_delete_internal(uuid,uuid);
alter function private.preview_customer_hard_delete_internal_before_order_guard(uuid[],uuid)
  rename to preview_customer_hard_delete_internal;
alter function private.complete_customer_hard_delete_internal_before_order_guard(uuid,uuid)
  rename to complete_customer_hard_delete_internal;
grant execute on function private.preview_customer_hard_delete_internal(uuid[],uuid),
  private.complete_customer_hard_delete_internal(uuid,uuid) to authenticated;
commit;
