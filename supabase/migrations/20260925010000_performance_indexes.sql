-- Migration: Add missing performance indexes on customer_id, task_type, and batch_id
CREATE INDEX IF NOT EXISTS idx_email_pin_records_customer_created ON public.email_pin_records (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mdac_registrations_customer_id ON public.mdac_registrations (customer_id);
CREATE INDEX IF NOT EXISTS idx_registration_checks_customer_checked ON public.registration_checks (customer_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_visit_pass_checks_customer_checked ON public.visit_pass_checks (customer_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_automation_batches_task_type_created ON public.automation_batches (task_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_automation_items_batch_created ON public.automation_items (batch_id, created_at);
