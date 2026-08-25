-- Allow a manually recorded or externally matched PIN to exist before a
-- corresponding automation batch item is available. Batch-linked PIN rows
-- continue to use the foreign key when batch_item_id is present.
alter table public.email_pin_records
  alter column batch_item_id drop not null;

comment on column public.email_pin_records.batch_item_id is
  'Nullable for manual or externally matched PIN records; populated for task-linked records.';
