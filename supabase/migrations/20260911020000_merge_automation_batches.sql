CREATE OR REPLACE FUNCTION public.merge_automation_batches(
    p_source_batch_id uuid,
    p_target_batch_id uuid,
    p_actor text DEFAULT 'operator'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_source public.automation_batches%ROWTYPE;
    v_target public.automation_batches%ROWTYPE;
    v_moved_count int := 0;
    v_is_owner boolean := false;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        SELECT p.role = 'OWNER' INTO v_is_owner
        FROM public.profiles p
        WHERE p.id = auth.uid() AND p.is_active AND p.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'active user required' USING errcode = '42501';
        END IF;
    END IF;

    IF p_source_batch_id = p_target_batch_id THEN
        RAISE EXCEPTION '源批次与目标批次不能相同';
    END IF;

    -- Lock in a stable order so authorization and mutation see the same rows.
    PERFORM 1 FROM public.automation_batches
    WHERE id IN (p_source_batch_id, p_target_batch_id)
    ORDER BY id FOR UPDATE;

    SELECT * INTO v_source FROM public.automation_batches WHERE id = p_source_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '源批次不存在';
    END IF;

    SELECT * INTO v_target FROM public.automation_batches WHERE id = p_target_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '目标批次不存在';
    END IF;
    IF v_source.task_type IS DISTINCT FROM v_target.task_type THEN
        RAISE EXCEPTION '不能合并不同类型的批次';
    END IF;
    IF auth.role() IS DISTINCT FROM 'service_role'
       AND NOT v_is_owner
       AND (v_source.created_by IS DISTINCT FROM auth.uid()
            OR v_target.created_by IS DISTINCT FROM auth.uid()) THEN
        RAISE EXCEPTION 'batch owner or Owner required' USING errcode = '42501';
    END IF;

    -- Delete any duplicate items in source where target already has that customer
    DELETE FROM public.automation_items
    WHERE batch_id = p_source_batch_id
      AND customer_id IN (
          SELECT customer_id FROM public.automation_items WHERE batch_id = p_target_batch_id
      );

    -- Move remaining items from source to target
    UPDATE public.automation_items
    SET batch_id = p_target_batch_id,
        updated_at = clock_timestamp()
    WHERE batch_id = p_source_batch_id;
    
    GET DIAGNOSTICS v_moved_count = ROW_COUNT;

    -- Update target batch counters
    UPDATE public.automation_batches
    SET total_count = (SELECT count(*) FROM public.automation_items WHERE batch_id = p_target_batch_id),
        success_count = (SELECT count(*) FROM public.automation_items WHERE batch_id = p_target_batch_id AND status = 'SUCCEEDED'),
        failed_count = (SELECT count(*) FROM public.automation_items WHERE batch_id = p_target_batch_id AND status IN ('FAILED', 'NEEDS_REVIEW')),
        updated_at = clock_timestamp()
    WHERE id = p_target_batch_id;

    -- Delete empty source batch
    DELETE FROM public.automation_batches WHERE id = p_source_batch_id;

    RETURN jsonb_build_object(
        'success', true,
        'moved_count', v_moved_count,
        'target_batch_id', p_target_batch_id
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.merge_customers_into_batch(
    p_customer_ids uuid[],
    p_target_batch_id uuid,
    p_actor text DEFAULT 'operator'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_target public.automation_batches%ROWTYPE;
    v_source_batch_ids uuid[];
    v_moved_count int := 0;
    v_cid uuid;
    v_is_owner boolean := false;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        SELECT p.role = 'OWNER' INTO v_is_owner
        FROM public.profiles p
        WHERE p.id = auth.uid() AND p.is_active AND p.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'active user required' USING errcode = '42501';
        END IF;
    END IF;

    IF p_customer_ids IS NULL OR cardinality(p_customer_ids) = 0
       OR array_position(p_customer_ids, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'valid customer ids required';
    END IF;

    -- Customer row locks prevent a concurrent batch-item FK insert from
    -- introducing an unchecked source while the merge is in progress.
    PERFORM 1 FROM public.customers
    WHERE id = ANY(p_customer_ids)
    ORDER BY id FOR UPDATE;

    -- A row lock on each parent batch also blocks new item references while
    -- the source set is checked and moved.
    PERFORM 1 FROM public.automation_batches b
    WHERE b.id = p_target_batch_id OR EXISTS (
        SELECT 1 FROM public.automation_items i
        WHERE i.batch_id = b.id AND i.customer_id = ANY(p_customer_ids)
          AND b.task_type = 'MDAC_REGISTRATION'
    )
    ORDER BY b.id FOR UPDATE;

    SELECT * INTO v_target FROM public.automation_batches WHERE id = p_target_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '目标批次不存在';
    END IF;
    IF v_target.task_type <> 'MDAC_REGISTRATION' THEN
        RAISE EXCEPTION '目标批次必须为 MDAC_REGISTRATION';
    END IF;
    IF auth.role() IS DISTINCT FROM 'service_role' AND NOT v_is_owner THEN
        IF v_target.created_by IS DISTINCT FROM auth.uid()
           OR EXISTS (
               SELECT 1 FROM public.automation_batches b
               JOIN public.automation_items i ON i.batch_id = b.id
               WHERE i.customer_id = ANY(p_customer_ids)
                 AND b.task_type = 'MDAC_REGISTRATION'
                 AND b.created_by IS DISTINCT FROM auth.uid()
           ) OR EXISTS (
               SELECT 1 FROM unnest(p_customer_ids) AS selected(customer_id)
               LEFT JOIN public.customers c ON c.id = selected.customer_id
               WHERE c.id IS NULL OR c.deleted_at IS NOT NULL
                  OR c.created_by IS DISTINCT FROM auth.uid()
           ) THEN
            RAISE EXCEPTION 'customer and batch owner or Owner required'
              USING errcode = '42501';
        END IF;
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

    -- Update target batch counters
    UPDATE public.automation_batches
    SET total_count = (SELECT count(*) FROM public.automation_items WHERE batch_id = p_target_batch_id),
        success_count = (SELECT count(*) FROM public.automation_items WHERE batch_id = p_target_batch_id AND status = 'SUCCEEDED'),
        failed_count = (SELECT count(*) FROM public.automation_items WHERE batch_id = p_target_batch_id AND status IN ('FAILED', 'NEEDS_REVIEW')),
        updated_at = clock_timestamp()
    WHERE id = p_target_batch_id;

    -- Clean up any empty source batches
    IF array_length(v_source_batch_ids, 1) > 0 THEN
        DELETE FROM public.automation_batches
        WHERE id = ANY(v_source_batch_ids)
          AND id NOT IN (SELECT DISTINCT batch_id FROM public.automation_items WHERE batch_id IS NOT NULL);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'moved_count', v_moved_count,
        'target_batch_id', p_target_batch_id
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.merge_automation_batches(uuid, uuid, text) FROM public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.merge_customers_into_batch(uuid[], uuid, text) FROM public, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.merge_automation_batches(uuid, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.merge_customers_into_batch(uuid[], uuid, text) TO authenticated, service_role;
