-- Migration: Add get_workers_health RPC to provide real-time status of all 5 automation workers
CREATE OR REPLACE FUNCTION public.get_workers_health()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'mdac', COALESCE((
      SELECT jsonb_build_object(
        'name', 'MDAC 自动注册',
        'worker_id', worker_id,
        'hostname', hostname,
        'status', status,
        'last_seen_at', last_seen_at,
        'is_online', (last_seen_at >= now() - interval '3 minutes')
      )
      FROM public.worker_heartbeats
      WHERE worker_id LIKE '%worker-desktop%' OR worker_id LIKE '%mdac%'
      ORDER BY last_seen_at DESC
      LIMIT 1
    ), jsonb_build_object('name', 'MDAC 自动注册', 'is_online', false)),

    'reg_check', COALESCE((
      SELECT jsonb_build_object(
        'name', '登记核验',
        'worker_id', worker_id,
        'hostname', hostname,
        'status', status,
        'last_seen_at', last_seen_at,
        'is_online', (last_seen_at >= now() - interval '3 minutes')
      )
      FROM public.worker_heartbeats
      WHERE worker_id LIKE '%reg-check%'
      ORDER BY last_seen_at DESC
      LIMIT 1
    ), jsonb_build_object('name', '登记核验', 'is_online', false)),

    'visit_pass', COALESCE((
      SELECT jsonb_build_object(
        'name', 'Visit Pass 核验',
        'worker_id', worker_id,
        'hostname', hostname,
        'status', status,
        'last_seen_at', last_seen_at,
        'is_online', (last_seen_at >= now() - interval '3 minutes')
      )
      FROM public.worker_heartbeats
      WHERE worker_id LIKE '%visit-pass%'
      ORDER BY last_seen_at DESC
      LIMIT 1
    ), jsonb_build_object('name', 'Visit Pass 核验', 'is_online', false)),

    'ocr', COALESCE((
      SELECT jsonb_build_object(
        'name', 'Azure 护照 OCR',
        'worker_id', worker_id,
        'hostname', hostname,
        'status', status,
        'last_seen_at', last_seen_at,
        'is_online', (last_seen_at >= now() - interval '3 minutes')
      )
      FROM public.worker_heartbeats
      WHERE worker_id LIKE '%ocr%'
      ORDER BY last_seen_at DESC
      LIMIT 1
    ), jsonb_build_object('name', 'Azure 护照 OCR', 'is_online', false)),

    'gmail_pin', COALESCE((
      SELECT jsonb_build_object(
        'name', 'Gmail PIN 抓取',
        'worker_id', worker_id,
        'hostname', hostname,
        'status', status,
        'last_seen_at', last_seen_at,
        'is_online', (last_seen_at >= now() - interval '3 minutes')
      )
      FROM public.worker_heartbeats
      WHERE worker_id LIKE '%gmail-pin%'
      ORDER BY last_seen_at DESC
      LIMIT 1
    ), jsonb_build_object('name', 'Gmail PIN 抓取', 'is_online', false))
  );
$$;

GRANT EXECUTE ON FUNCTION public.get_workers_health() TO authenticated, anon, service_role;
