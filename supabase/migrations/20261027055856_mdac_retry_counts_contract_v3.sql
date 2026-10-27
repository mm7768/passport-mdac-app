-- Counters describe current items, never attempts or review outcomes as successes.
-- This migration is staged for review; production application requires approval.
create or replace function private.normalize_automation_batch_counts_v3()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 select count(*)::integer,
        count(*) filter(where status::text='SUCCEEDED')::integer,
        count(*) filter(where status::text='FAILED')::integer
 into new.total_count,new.success_count,new.failed_count
 from public.automation_items where batch_id=new.id;
 return new;
end $$;
revoke all on function private.normalize_automation_batch_counts_v3() from public,anon,authenticated,service_role;
create trigger normalize_automation_batch_counts_v3
before update of total_count,success_count,failed_count on public.automation_batches
for each row execute function private.normalize_automation_batch_counts_v3();

CREATE OR REPLACE FUNCTION private.sync_batch_status_and_counts(p_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_total int; v_success int; v_failed int; v_running int;
  v_queued int; v_review int; v_status public.automation_status;
begin
  select count(*)::int,
    count(*) filter (where status='SUCCEEDED')::int,
    count(*) filter (where status='FAILED')::int,
    count(*) filter (where status in ('CLAIMED','RUNNING'))::int,
    count(*) filter (where status='QUEUED')::int,
    count(*) filter (where status='NEEDS_REVIEW')::int
  into v_total,v_success,v_failed,v_running,v_queued,v_review
  from public.automation_items where batch_id=p_batch_id;
  select status into v_status from public.automation_batches
  where id=p_batch_id for update;
  if not found then return; end if;
  if v_total>0 then
    if v_running>0 then v_status:='RUNNING';
    elsif v_queued>0 then v_status:='QUEUED';
    elsif v_review>0 then v_status:='NEEDS_REVIEW';
    elsif v_failed=v_total then v_status:='FAILED';
    elsif v_success=v_total then v_status:='SUCCEEDED';
    elsif v_success+v_failed=v_total then v_status:='PARTIAL_SUCCESS';
    end if;
  end if;
  update public.automation_batches
  set total_count=v_total,success_count=v_success,failed_count=v_failed,
    status=v_status,updated_at=clock_timestamp() where id=p_batch_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.requeue_automation_batch(p_batch_id uuid)
 RETURNS public.automation_batches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b public.automation_batches; prior_attempts jsonb;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' and not private.is_active_user() then raise exception 'Active user required' using errcode='42501'; end if;
 select * into b from public.automation_batches where id=p_batch_id for update;
 if not found then raise exception 'Batch not found'; end if;
 if coalesce(auth.jwt()->>'role','')<>'service_role' and b.created_by is distinct from auth.uid() then
   raise exception 'Only the batch owner may retry it' using errcode='42501'; end if;
 if b.attempt_count>=5 then raise exception 'Batch attempt limit reached; manual review required'; end if;
 perform 1 from public.automation_items where batch_id=p_batch_id order by id for update;
 if b.lease_expires_at>clock_timestamp() or exists(select 1 from public.automation_items where batch_id=p_batch_id
   and (status::text in ('CLAIMED','RUNNING','QUEUED') or result_unknown
        or (submission_started_at is not null and status::text<>'SUCCEEDED'))) then
   raise exception 'G1/G2: active or uncertain work cannot be automatically requeued'; end if;
 if exists(select 1 from public.automation_items i join public.automation_items other_item
 on other_item.customer_id=i.customer_id and other_item.id<>i.id
 where i.batch_id=p_batch_id and i.status::text='FAILED' and not i.result_unknown
 and i.submission_started_at is null and i.attempt_count<5
 and other_item.status::text in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')) then
 raise exception 'G1/G2: customer has another active task'; end if;
 select jsonb_agg(jsonb_build_object('item_id',id,'attempt_count',attempt_count,'error_code',error_code))
 into prior_attempts from public.automation_items where batch_id=p_batch_id
 and status::text='FAILED' and not result_unknown and submission_started_at is null and attempt_count<5;
 update public.automation_items set status='QUEUED'  ,locked_by=null,locked_at=null,lease_expires_at=null,
   claim_token=null,external_started_at=null,started_at=null,finished_at=null,error_code=null,error_message=null
 where batch_id=p_batch_id and status::text='FAILED' and not result_unknown and submission_started_at is null and attempt_count<5;
 if not found then raise exception 'No safely retryable failed items'; end if;
 update public.automation_batches set locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=p_batch_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'AUTOMATION_SAFE_RETRY','automation_batches',p_batch_id,
 jsonb_build_object('prior_attempts',prior_attempts,'attempt_history_preserved',true));
 perform private.sync_batch_status_and_counts(p_batch_id);
 select * into b from public.automation_batches where id=p_batch_id;
 return b;
end $function$
;
CREATE OR REPLACE FUNCTION public.get_latest_task_dashboard()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        b.updated_at, b.attempt_count, b.lease_expires_at
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
            'case_id', i.case_id,
            'submission_started_at', i.submission_started_at,
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
    LEFT JOIN LATERAL (SELECT r.* FROM public.mdac_registrations r WHERE r.batch_item_id=i.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1) reg ON true
    LEFT JOIN LATERAL (SELECT r.* FROM public.registration_checks r WHERE r.batch_item_id=i.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1) rc ON true
    LEFT JOIN LATERAL (SELECT r.* FROM public.visit_pass_checks r WHERE r.batch_item_id=i.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1) vpc ON true
    LEFT JOIN LATERAL (SELECT r.* FROM public.email_pin_records r WHERE r.batch_item_id=i.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1) pin ON true
)
SELECT COALESCE(
    jsonb_agg(
        jsonb_build_object(
            'id', lb.id,
            'count_contract_version', 3,
            'attempt_count', lb.attempt_count,
            'lease_expires_at', lb.lease_expires_at,
            'task_type', lb.task_type,
            'status', lb.status,
            'total_count', counts.total_count,
            'success_count', counts.success_count,
            'failed_count', counts.failed_count,
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
FROM latest_batches lb
CROSS JOIN LATERAL (
 SELECT count(*)::integer total_count,
 count(*) FILTER(WHERE i.status::text='SUCCEEDED')::integer success_count,
 count(*) FILTER(WHERE i.status::text='FAILED')::integer failed_count
 FROM public.automation_items i WHERE i.batch_id=lb.id
) counts;
$function$
;

-- Preserve the existing role boundary explicitly; no Worker permission is added.
revoke all on function public.requeue_automation_batch(uuid) from public,anon;
grant execute on function public.requeue_automation_batch(uuid) to authenticated,service_role;
revoke all on function public.get_latest_task_dashboard() from public,anon;
grant execute on function public.get_latest_task_dashboard() to authenticated,service_role;
notify pgrst,'reload schema';
