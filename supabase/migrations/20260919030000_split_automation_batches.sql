-- The old split implementation called this helper, but never defined it.
-- Keep the same status/count semantics as the automation_items trigger.
CREATE OR REPLACE FUNCTION private.sync_batch_status_and_counts(p_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_total int;
    v_succeeded int;
    v_failed int;
    v_running int;
    v_queued int;
    v_review int;
    v_status public.automation_status;
BEGIN
    SELECT count(*)::int,
           count(*) FILTER (WHERE status IN ('SUCCEEDED', 'NEEDS_REVIEW'))::int,
           count(*) FILTER (WHERE status = 'FAILED')::int,
           count(*) FILTER (WHERE status IN ('CLAIMED', 'RUNNING'))::int,
           count(*) FILTER (WHERE status = 'QUEUED')::int,
           count(*) FILTER (WHERE status = 'NEEDS_REVIEW')::int
    INTO v_total, v_succeeded, v_failed, v_running, v_queued, v_review
    FROM public.automation_items WHERE batch_id = p_batch_id;

    SELECT status INTO v_status FROM public.automation_batches
    WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;

    IF v_total > 0 THEN
        IF v_running > 0 THEN v_status := 'RUNNING';
        ELSIF v_queued > 0 THEN v_status := 'QUEUED';
        ELSIF v_review > 0 THEN v_status := 'NEEDS_REVIEW';
        ELSIF v_failed = v_total THEN v_status := 'FAILED';
        ELSIF v_succeeded = v_total THEN v_status := 'SUCCEEDED';
        ELSIF v_succeeded + v_failed = v_total THEN v_status := 'PARTIAL_SUCCESS';
        END IF;
    END IF;

    UPDATE public.automation_batches
    SET total_count = v_total, success_count = v_succeeded,
        failed_count = v_failed, status = v_status, updated_at = clock_timestamp()
    WHERE id = p_batch_id;
END;
$function$;
REVOKE ALL ON FUNCTION private.sync_batch_status_and_counts(uuid)
FROM public, anon, authenticated;

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
        RAISE EXCEPTION '请至少选择一位客户进行拆分';
    END IF;

    SELECT * INTO v_source FROM public.automation_batches
    WHERE id = p_source_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION '源批次不存在';
    END IF;
    IF auth.role() IS DISTINCT FROM 'service_role' AND NOT v_is_owner
       AND v_source.created_by IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'batch owner or Owner required' USING errcode = '42501';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.automation_items
        WHERE batch_id = p_source_batch_id AND customer_id = ANY(p_customer_ids)
    ) THEN
        RAISE EXCEPTION '选中的客户不在该批次中';
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
DECLARE
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

    UPDATE public.automation_batches
    SET note = trim(p_note),
        updated_at = clock_timestamp()
    WHERE id = p_batch_id
      AND (auth.role() = 'service_role' OR v_is_owner OR created_by = auth.uid());

    IF NOT FOUND THEN
        RAISE EXCEPTION 'batch owner or Owner required' USING errcode = '42501';
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.split_customers_from_batch(uuid, uuid[], text, text) FROM public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_automation_batch_note(uuid, text) FROM public, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.split_customers_from_batch(uuid, uuid[], text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_automation_batch_note(uuid, text) TO authenticated, service_role;
