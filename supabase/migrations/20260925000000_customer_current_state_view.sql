-- Migration: Add customer_current_state view to aggregate customer + latest pin_record + profiles.name
CREATE OR REPLACE VIEW public.customer_current_state
WITH (security_invoker = true)
AS
SELECT 
    c.id,
    c.full_name,
    c.date_of_birth,
    c.place_of_birth,
    c.passport_number,
    c.nationality,
    c.gender,
    c.passport_expiry_date,
    c.passport_image_path,
    c.business_status,
    c.created_by,
    c.created_at,
    c.deleted_at,
    COALESCE(p.name, c.created_by::text) AS created_by_name,
    pin.record AS pin_record
FROM public.customers c
LEFT JOIN public.profiles p ON p.id = c.created_by
LEFT JOIN LATERAL (
    SELECT jsonb_build_object(
        'customer_id', e.customer_id,
        'pin_value', e.pin_value,
        'status', e.status,
        'received_at', e.received_at,
        'created_at', e.created_at
    ) AS record
    FROM public.email_pin_records e
    WHERE e.customer_id = c.id
    ORDER BY e.created_at DESC
    LIMIT 1
) pin ON true
WHERE c.deleted_at IS NULL;

GRANT SELECT ON public.customer_current_state TO authenticated, service_role;
