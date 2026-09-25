-- Migration: Add get_latest_task_dashboard RPC to fetch latest batches + items + results in 1 call
CREATE OR REPLACE FUNCTION public.get_latest_task_dashboard()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
AS 
WITH latest_batches AS (
    SELECT DISTINCT ON (b.task_type)
        b.id,
        b.task_type::text AS task_type,
        b.status::text AS status,
        b.total_count,
        b.success_count,
        b.failed_count,
        b.entry_date,
        b.exit_date,
        b.mdac_settings_snapshot,
        b.note,
        b.created_by,
        b.created_at,
        b.updated_at
    FROM public.automation_batches b
    WHERE b.task_type IN ('MDAC_REGISTRATION', 'GMAIL_PIN', 'REGISTRATION_CHECK', 'VISIT_PASS_CHECK')
    ORDER BY b.task_type, b.created_at DESC
),
batch_items AS (
    SELECT 
        i.batch_id,
        i.created_at AS item_created_at,
        jsonb_build_object(
            'id', i.id,
            'batch_id', i.batch_id,
            'customer_id', i.customer_id,
            'customer_snapshot', i.customer_snapshot,
            'status', i.status::text,
            'attempt_count', i.attempt_count,
            'error_code', i.error_code,
            'error_message', i.error_message,
            'result_unknown', i.result_unknown,
            'created_at', i.created_at,
            'updated_at', i.updated_at,
            'registration', CASE 
                WHEN lb.task_type = 'MDAC_REGISTRATION' AND reg.batch_item_id IS NOT NULL 
                THEN jsonb_build_object(
                    'batch_item_id', reg.batch_item_id,
                    'registration_no', reg.registration_no,
                    'registration_status', reg.registration_status,
                    'raw_summary', reg.raw_summary,
                    'screenshot_path', reg.screenshot_path,
                    'submitted_at', reg.submitted_at,
                    'result_confirmed_at', reg.result_confirmed_at,
                    'updated_at', reg.updated_at
                )
                ELSE NULL 
            END,
            'registration_check', CASE 
                WHEN lb.task_type = 'REGISTRATION_CHECK' AND rc.batch_item_id IS NOT NULL 
                THEN jsonb_build_object(
                    'batch_item_id', rc.batch_item_id,
                    'checked_at', rc.checked_at,
                    'result_status', rc.result_status,
                    'raw_summary', rc.raw_summary,
                    'normalized_status', rc.normalized_status,
                    'error_message', rc.error_message,
                    'screenshot_path', rc.screenshot_path,
                    'challenge_type', rc.challenge_type,
                    'submitted', rc.submitted,
                    'result_confirmed', rc.result_confirmed,
                    'updated_at', rc.updated_at
                )
                ELSE NULL 
            END,
            'visit_pass_check', CASE 
                WHEN lb.task_type = 'VISIT_PASS_CHECK' AND vpc.batch_item_id IS NOT NULL 
                THEN jsonb_build_object(
                    'batch_item_id', vpc.batch_item_id,
                    'checked_at', vpc.checked_at,
                    'result_status', vpc.result_status,
                    'raw_summary', vpc.raw_summary,
                    'normalized_status', vpc.normalized_status,
                    'error_message', vpc.error_message,
                    'screenshot_path', vpc.screenshot_path,
                    'challenge_type', vpc.challenge_type,
                    'submitted', vpc.submitted,
                    'result_confirmed', vpc.result_confirmed,
                    'updated_at', vpc.updated_at
                )
                ELSE NULL 
            END,
            'pin_record', CASE 
                WHEN lb.task_type = 'GMAIL_PIN' AND pin.batch_item_id IS NOT NULL 
                THEN jsonb_build_object(
                    'customer_id', pin.customer_id,
                    'batch_item_id', pin.batch_item_id,
                    'pin_value', pin.pin_value,
                    'status', pin.status,
                    'raw_summary', pin.raw_summary,
                    'received_at', pin.received_at,
                    'created_at', pin.created_at
                )
                ELSE NULL 
            END
        ) AS item_obj
    FROM public.automation_items i
    JOIN latest_batches lb ON lb.id = i.batch_id
    LEFT JOIN public.mdac_registrations reg ON reg.batch_item_id = i.id
    LEFT JOIN public.registration_checks rc ON rc.batch_item_id = i.id
    LEFT JOIN public.visit_pass_checks vpc ON vpc.batch_item_id = i.id
    LEFT JOIN public.email_pin_records pin ON pin.batch_item_id = i.id
)
SELECT COALESCE(
    jsonb_agg(
        jsonb_build_object(
            'id', lb.id,
            'task_type', lb.task_type,
            'status', lb.status,
            'total_count', lb.total_count,
            'success_count', lb.success_count,
            'failed_count', lb.failed_count,
            'entry_date', lb.entry_date,
            'exit_date', lb.exit_date,
            'mdac_settings_snapshot', lb.mdac_settings_snapshot,
            'note', lb.note,
            'created_by', lb.created_by,
            'created_at', lb.created_at,
            'updated_at', lb.updated_at,
            'items', COALESCE(
                (
                    SELECT jsonb_agg(bi.item_obj ORDER BY bi.item_created_at) 
                    FROM batch_items bi 
                    WHERE bi.batch_id = lb.id
                ),
                '[]'::jsonb
            )
        )
        ORDER BY lb.created_at DESC
    ),
    '[]'::jsonb
)
FROM latest_batches lb;
;

GRANT EXECUTE ON FUNCTION public.get_latest_task_dashboard() TO authenticated, anon, service_role;
