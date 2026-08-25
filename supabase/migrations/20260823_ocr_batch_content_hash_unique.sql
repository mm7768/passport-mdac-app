-- Protect against duplicate successful uploads across devices.
-- The hash is stored in metadata and is not a secret.
create unique index if not exists ocr_batches_uploaded_content_hash_uq
on public.ocr_batches ((metadata ->> 'content_hash'))
where status <> 'FAILED' and metadata ? 'content_hash';
