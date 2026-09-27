-- Migration: Add get_mdac_batch_memberships RPC for lightweight customer batch grouping
-- Returns only batch_id, name (from note), created_at, and customer_ids array.
-- Strictly avoids loading heavy registration results, screenshots, worker logs, etc.

CREATE OR REPLACE FUNCTION public.get_mdac_batch_memberships()
RETURNS TABLE (
    batch_id uuid,
    name text,
    created_at timestamptz,
    customer_ids uuid[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        b.id AS batch_id,
        COALESCE(NULLIF(TRIM(b.note), ''), '1') AS name,
        b.created_at,
        ARRAY_AGG(i.customer_id ORDER BY i.created_at) AS customer_ids
    FROM public.automation_batches b
    JOIN public.automation_items i
      ON i.batch_id = b.id
    WHERE b.task_type = 'MDAC_REGISTRATION'
    GROUP BY
        b.id,
        b.note,
        b.created_at
    ORDER BY
        b.created_at DESC;
$$;

GRANT EXECUTE
ON FUNCTION public.get_mdac_batch_memberships()
TO authenticated, anon, service_role;
