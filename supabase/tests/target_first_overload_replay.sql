-- ISOLATED ONLY. Production read-only snapshot of the legacy overload.
-- It is immediately guarded in the SAME uncommitted transaction. No business data copied.
begin;
CREATE OR REPLACE FUNCTION public.merge_customers_into_batch(p_target_batch_id uuid, p_customer_ids uuid[], p_actor text DEFAULT 'operator'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
DECLARE
    v_target public.automation_batches%ROWTYPE;
    v_source_batch_ids uuid[];
    v_moved_count int := 0;
    v_cid uuid;
    v_s_bid uuid;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' AND NOT private.is_active_user() THEN
        RAISE EXCEPTION 'active user required';
    END IF;

    SELECT * INTO v_target FROM public.automation_batches WHERE id = p_target_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '目标批次不存在';
    END IF;

    -- Find all distinct source batches of these customers for MDAC_REGISTRATION
    SELECT coalesce(array_agg(DISTINCT i.batch_id), array[]::uuid[]) INTO v_source_batch_ids
    FROM public.automation_items i
    JOIN public.automation_batches b ON b.id = i.batch_id
    WHERE i.customer_id = ANY(p_customer_ids)
      AND b.task_type = 'MDAC_REGISTRATION'
      AND i.batch_id <> p_target_batch_id;

    -- For each customer:
    FOREACH v_cid IN ARRAY p_customer_ids LOOP
        IF EXISTS (SELECT 1 FROM public.automation_items WHERE batch_id = p_target_batch_id AND customer_id = v_cid) THEN
            -- already in target batch, do nothing
            CONTINUE;
        ELSIF EXISTS (
            SELECT 1 FROM public.automation_items i
            JOIN public.automation_batches b ON b.id = i.batch_id
            WHERE i.customer_id = v_cid AND b.task_type = 'MDAC_REGISTRATION'
        ) THEN
            -- delete duplicate old items except one
            DELETE FROM public.automation_items
            WHERE id IN (
                SELECT i.id FROM public.automation_items i
                JOIN public.automation_batches b ON b.id = i.batch_id
                WHERE i.customer_id = v_cid AND b.task_type = 'MDAC_REGISTRATION'
                ORDER BY i.created_at DESC
                OFFSET 1
            );
            -- update the remaining one to target batch
            UPDATE public.automation_items
            SET batch_id = p_target_batch_id,
                updated_at = clock_timestamp()
            WHERE id IN (
                SELECT i.id FROM public.automation_items i
                JOIN public.automation_batches b ON b.id = i.batch_id
                WHERE i.customer_id = v_cid AND b.task_type = 'MDAC_REGISTRATION'
            );
            v_moved_count := v_moved_count + 1;
        ELSE
            -- insert a new item
            INSERT INTO public.automation_items (
                batch_id, customer_id, status, created_at, updated_at
            ) VALUES (
                p_target_batch_id, v_cid, 'SUCCEEDED', clock_timestamp(), clock_timestamp()
            );
            v_moved_count := v_moved_count + 1;
        END IF;
    END LOOP;

    -- If any customer was PENDING or ACTION_REQUIRED, advance their business status
    UPDATE public.customers
    SET business_status = 'MDAC_REGISTERED',
        updated_at = clock_timestamp()
    WHERE id = ANY(p_customer_ids)
      AND business_status IN ('PENDING', 'ACTION_REQUIRED');

    -- Re-evaluate target batch
    PERFORM private.sync_batch_status_and_counts(p_target_batch_id);

    -- Clean up any empty source batches or sync remaining
    IF array_length(v_source_batch_ids, 1) > 0 THEN
        FOREACH v_s_bid IN ARRAY v_source_batch_ids LOOP
            IF (SELECT count(*) FROM public.automation_items WHERE batch_id = v_s_bid) = 0 THEN
                DELETE FROM public.automation_batches WHERE id = v_s_bid;
            ELSE
                PERFORM private.sync_batch_status_and_counts(v_s_bid);
            END IF;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'moved_count', v_moved_count,
        'target_batch_id', p_target_batch_id
    );
END;
$function$;

\ir ../migrations/20261003132646_customer_batch_overload_owner_guard.sql
\ir automation_batch_owner_guard.sql
-- The included test rolls back the entire transaction, including this overload.
