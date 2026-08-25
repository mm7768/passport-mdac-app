-- Store non-secret file metadata for upload audit and idempotency.
-- The raw file remains in the private passport-documents bucket.
alter table public.ocr_batches
  add column if not exists metadata jsonb not null default '{}'::jsonb;

comment on column public.ocr_batches.metadata is
  'Non-secret upload metadata such as original filename, MIME type, size and SHA-256 content hash.';
