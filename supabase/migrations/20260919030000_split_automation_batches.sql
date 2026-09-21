CREATE OR REPLACE FUNCTION public.split_customers_from_batch(
    p_source_batch_id uuid,
    p_customer_ids uuid[],
    p_new_batch_name text DEFAULT '1',
    p_actor text DEFAULT 'operator'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_source public.automation_batches%ROWTYPE;
    v_new_batch_id uuid;
    v_moved_count int := 0;
    v_batch_name text;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' AND NOT private.is_active_user() THEN
        RAISE EXCEPTION 'active user required';
    END IF;

    IF array_length(p_customer_ids, 1) IS NULL OR array_length(p_customer_ids, 1) = 0 THEN
        RAISE EXCEPTION '请至少选择一位客户进行拆分';
    END IF;

    SELECT * INTO v_source FROM public.automation_batches WHERE id = p_source_batch_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '源批次不存在';
    END IF;

    v_batch_name := coalesce(nullif(trim(p_new_batch_name), ''), '1');

    -- Create new batch record mirroring source batch properties
    v_new_batch_id := gen_random_uuid();
    INSERT INTO public.automation_batches (
        id,
        task_type,
        status,
        entry_date,
        exit_date,
        mdac_settings_snapshot,
        gmail_settings_snapshot,
        visit_pass_settings_snapshot,
        note,
        created_by,
        created_at,
        updated_at
    ) VALUES (
        v_new_batch_id,
        v_source.task_type,
        v_source.status,
        v_source.entry_date,
        v_source.exit_date,
        v_source.mdac_settings_snapshot,
        v_source.gmail_settings_snapshot,
        v_source.visit_pass_settings_snapshot,
        v_batch_name,
        v_source.created_by,
        clock_timestamp(),
        clock_timestamp()
    );

    -- Move selected customer automation_items to new batch
    UPDATE public.automation_items
    SET batch_id = v_new_batch_id,
        updated_at = clock_timestamp()
    WHERE batch_id = p_source_batch_id
      AND customer_id = ANY(p_customer_ids);

    GET DIAGNOSTICS v_moved_count = ROW_COUNT;

    -- Clean up empty source batch if all items were split out
    IF (SELECT count(*) FROM public.automation_items WHERE batch_id = p_source_batch_id) = 0 THEN
        DELETE FROM public.automation_batches WHERE id = p_source_batch_id;
    ELSE
        -- Recalculate status and counters for source batch
        PERFORM private.sync_batch_status_and_counts(p_source_batch_id);
    END IF;

    -- Recalculate status and counters for new batch
    PERFORM private.sync_batch_status_and_counts(v_new_batch_id);

    RETURN jsonb_build_object(
        'success', true,
        'new_batch_id', v_new_batch_id,
        'split_count', v_moved_count,
        'new_batch_name', v_batch_name
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_automation_batch_note(
    p_batch_id uuid,
    p_note text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' AND NOT private.is_active_user() THEN
        RAISE EXCEPTION 'active user required';
    END IF;

    UPDATE public.automation_batches
    SET note = trim(p_note),
        updated_at = clock_timestamp()
    WHERE id = p_batch_id;

    RETURN jsonb_build_object('success', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.split_customers_from_batch(uuid, uuid[], text, text) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.update_automation_batch_note(uuid, text) TO authenticated, service_role, anon;
