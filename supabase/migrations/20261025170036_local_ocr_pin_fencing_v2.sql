-- One local executor per service. No legacy queue reset or customer cleanup.
lock table public.ocr_batches,public.ocr_results in share row exclusive mode;
do $$ begin
 if exists(select 1 from public.ocr_batches where status::text='PROCESSING') then
   raise exception 'Drain active OCR tasks before installing OCR fencing'; end if;
 if exists(select 1 from public.automation_items i join public.automation_batches b on b.id=i.batch_id
   where b.task_type::text='GMAIL_PIN' and i.status::text in ('RUNNING','CLAIMED')) then
   raise exception 'Drain active PIN tasks before installing PIN fencing'; end if;
end $$;
create or replace function public.claim_gmail_pin_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='GMAIL_PIN'
 and (q.attempt_count<p_max_attempts or (q.status::text in ('CLAIMED','RUNNING') and q.lease_expires_at<=clock_timestamp())) and (
   (q.status::text='QUEUED' and (q.locked_by is null or q.lease_expires_at<=clock_timestamp())
    and exists(select 1 from public.automation_items i where i.batch_id=q.id and i.status::text='QUEUED'
      and not i.result_unknown and i.attempt_count<p_max_attempts
      and (i.next_attempt_at is null or i.next_attempt_at<=clock_timestamp())))
   or (q.status::text in ('CLAIMED','RUNNING') and q.lease_expires_at<=clock_timestamp()))
 order by q.created_at,q.id limit 1 for update skip locked;
 if not found then return; end if;
 -- Any abandoned execution is uncertain, even if it crashed before recording a response.
 update public.automation_items set status='NEEDS_REVIEW',result_unknown=true,
   locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,
   error_code='LEASE_EXPIRED_REVIEW',error_message='Abandoned execution requires review; automatic replay is blocked'
 where batch_id=b.id and status::text in ('CLAIMED','RUNNING');
 if b.attempt_count>=p_max_attempts then
   update public.automation_items set status='NEEDS_REVIEW',result_unknown=false,
     error_code='BATCH_ATTEMPT_LIMIT',error_message='Unstarted item requires review after repeated batch startup failures'
   where batch_id=b.id and status::text='QUEUED';
 end if;
 if not exists(select 1 from public.automation_items i where i.batch_id=b.id and i.status::text='QUEUED'
   and not i.result_unknown and i.attempt_count<p_max_attempts
   and (i.next_attempt_at is null or i.next_attempt_at<=clock_timestamp())) then
   update public.automation_batches set locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=b.id;
   perform private.sync_batch_status_and_counts(b.id); return;
 end if;
 update public.automation_batches set status='CLAIMED',locked_by=p_worker_id,locked_at=clock_timestamp(),
   lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),attempt_count=attempt_count+1,
   claim_token=gen_random_uuid() where id=b.id returning * into b;
 return next b;
end $$;
create or replace function public.claim_gmail_pin_item(p_batch_id uuid,p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_items language plpgsql security definer set search_path='' as $$
declare i public.automation_items;
begin
 perform private.mdac_require_fence(p_worker_id,p_batch_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 if not exists(select 1 from public.automation_batches where id=p_batch_id and task_type::text='GMAIL_PIN') then raise exception 'Wrong task type'; end if;
 select * into i from public.automation_items q where q.batch_id=p_batch_id and q.status::text='QUEUED'
 and not q.result_unknown and q.attempt_count<p_max_attempts
 and (q.next_attempt_at is null or q.next_attempt_at<=clock_timestamp())
 order by q.created_at,q.id limit 1 for update skip locked;
 if not found then return; end if;
 update public.automation_items set status='RUNNING',locked_by=p_worker_id,locked_at=clock_timestamp(),
 lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),attempt_count=attempt_count+1,
 started_at=coalesce(started_at,clock_timestamp()),claim_token=gen_random_uuid(),external_started_at=null,
 submission_started_at=null,error_code=null,error_message=null where id=i.id returning * into i;
 return next i;
end $$;
CREATE OR REPLACE FUNCTION public.heartbeat_gmail_pin(p_worker_id text, p_batch_id uuid DEFAULT NULL::uuid, p_item_id uuid DEFAULT NULL::uuid, p_lease_seconds integer DEFAULT 900, p_status worker_status DEFAULT 'ONLINE'::worker_status, p_hostname text DEFAULT 'railway'::text, p_version text DEFAULT 'gmail-pin-1'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_now timestamptz := now();
begin
 perform private.mdac_require_fence(p_worker_id,p_batch_id,p_item_id);
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if p_lease_seconds < 60 or p_lease_seconds > 3600 then
    raise exception 'lease_seconds must be between 60 and 3600';
  end if;

  insert into public.worker_heartbeats (
    worker_id, hostname, version, status, current_batch_id, last_seen_at, metadata
  ) values (
    p_worker_id,
    coalesce(nullif(trim(p_hostname), ''), 'railway'),
    coalesce(nullif(trim(p_version), ''), 'gmail-pin-1'),
    p_status,
    case when p_status = 'BUSY' then p_batch_id else null end,
    v_now,
    jsonb_build_object('execution_mode', 'GMAIL_PIN', 'pin_value_logged', false)
  )
  on conflict (worker_id) do update set
    hostname = excluded.hostname,
    version = excluded.version,
    status = excluded.status,
    current_batch_id = excluded.current_batch_id,
    last_seen_at = excluded.last_seen_at,
    metadata = excluded.metadata;

  if p_status = 'BUSY' and p_batch_id is not null then
    update public.automation_batches
       set locked_at = v_now,
           lease_expires_at = v_now + make_interval(secs => p_lease_seconds)
     where id = p_batch_id
       and locked_by = p_worker_id;
  end if;

  if p_status = 'BUSY' and p_item_id is not null then
    update public.automation_items
       set locked_at = v_now,
           lease_expires_at = v_now + make_interval(secs => p_lease_seconds)
     where id = p_item_id
       and locked_by = p_worker_id
       and status in ('CLAIMED', 'RUNNING');
  end if;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.finish_gmail_pin_item(p_item_id uuid, p_worker_id text, p_pin_status pin_status, p_max_attempts integer DEFAULT 12, p_email_message_id text DEFAULT NULL::text, p_sender text DEFAULT NULL::text, p_subject text DEFAULT NULL::text, p_pin_value text DEFAULT NULL::text, p_match_confidence numeric DEFAULT NULL::numeric, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_received_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.automation_items;
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'pin_value_logged', false,
      'email_body_stored', false
    );
  v_terminal_status public.automation_item_status;
  v_next_business_status public.business_status;
  v_next_attempt_at timestamptz;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_has_ready_items boolean;
  v_has_active_items boolean;
  v_has_review_items boolean;
begin
 perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;
  if p_pin_status = 'RECEIVED' and nullif(trim(coalesce(p_pin_value, '')), '') is null then
    raise exception 'RECEIVED PIN result requires a non-empty pin_value';
  end if;
  if p_pin_status <> 'RECEIVED' and p_pin_value is not null then
    raise exception 'non-RECEIVED PIN result must not contain pin_value';
  end if;

  select * into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING');
  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  -- Verify customer is not deleted.
  if not exists (
    select 1 from public.customers c
     where c.id = v_item.customer_id
       and c.deleted_at is null
  ) then
    -- Mark item failed without reviving or mutating deleted customer.
    update public.automation_items
       set status = 'FAILED',
           finished_at = now(),
           locked_by = null,
           locked_at = null,
           lease_expires_at = null,
           error_code = 'CUSTOMER_DELETED',
           error_message = 'Customer was deleted before task completion'
     where id = v_item.id;
    select * into v_item from public.automation_items where id = v_item.id;
    return v_item;
  end if;

  -- Verify passport consistency if customer snapshot contains passport_number.
  if nullif(trim(v_item.customer_snapshot->>'passport_number'), '') is not null then
    if not exists (
      select 1 from public.customers c
       where c.id = v_item.customer_id
         and regexp_replace(upper(c.passport_number), '[^A-Z0-9]', '', 'g') =
             regexp_replace(upper(v_item.customer_snapshot->>'passport_number'), '[^A-Z0-9]', '', 'g')
    ) then
      update public.automation_items
         set status = 'NEEDS_REVIEW',
             finished_at = now(),
             locked_by = null,
             locked_at = null,
             lease_expires_at = null,
             error_code = 'CUSTOMER_PASSPORT_MODIFIED',
             error_message = 'Customer passport number changed after task was enqueued'
       where id = v_item.id;
      select * into v_item from public.automation_items where id = v_item.id;
      return v_item;
    end if;
  end if;

  if p_pin_status = 'RECEIVED' then
    v_terminal_status := 'SUCCEEDED';
    v_next_business_status := 'PIN_RECEIVED';
  elsif p_pin_status = 'NOT_FOUND' and v_item.attempt_count < p_max_attempts then
    v_terminal_status := 'QUEUED';
    v_next_business_status := null;
    v_next_attempt_at := now() + interval '5 minutes';
    v_error_code := coalesce(p_error_code, 'PIN_NOT_FOUND_RETRY');
    v_error_message := coalesce(p_error_message, 'No matching PIN email found; retry scheduled in 5 minutes');
  else
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(
      p_error_code,
      case
        when p_pin_status = 'PARSE_FAILED' then 'PIN_PARSE_FAILED'
        when p_pin_status = 'NOT_FOUND' then 'PIN_MAX_ATTEMPTS_REACHED'
        else 'PIN_NEEDS_REVIEW'
      end
    );
    v_error_message := coalesce(p_error_message, 'Gmail PIN requires manual review');
  end if;

  insert into public.email_pin_records (
    customer_id,
    batch_item_id,
    email_message_id,
    sender,
    subject,
    matched_by,
    pin_value,
    match_confidence,
    status,
    raw_summary,
    received_at
  ) values (
    v_item.customer_id,
    v_item.id,
    nullif(trim(p_email_message_id), ''),
    nullif(trim(p_sender), ''),
    nullif(trim(p_subject), ''),
    case when p_pin_status = 'RECEIVED' then 'GMAIL_IMAP_PASSPORT' else 'GMAIL_IMAP' end,
    case when p_pin_status = 'RECEIVED' then trim(p_pin_value) else null end,
    p_match_confidence,
    p_pin_status,
    v_summary,
    p_received_at
  )
  on conflict (batch_item_id) do update set
    email_message_id = excluded.email_message_id,
    sender = excluded.sender,
    subject = excluded.subject,
    matched_by = excluded.matched_by,
    pin_value = excluded.pin_value,
    match_confidence = excluded.match_confidence,
    status = excluded.status,
    raw_summary = excluded.raw_summary,
    received_at = excluded.received_at,
    updated_at = now();

  update public.automation_items
     set status = v_terminal_status,
         finished_at = case when v_terminal_status = 'QUEUED' then null else now() end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         next_attempt_at = v_next_attempt_at,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = false
   where id = v_item.id;

  if v_next_business_status is not null then
    update public.customers
       set business_status = v_next_business_status,
           updated_at = now()
     where id = v_item.customer_id;
  end if;

  select
    exists (
      select 1
        from public.automation_items i
       where i.batch_id = v_item.batch_id
         and i.status = 'QUEUED'
         and i.attempt_count < p_max_attempts
         and (i.next_attempt_at is null or i.next_attempt_at <= now())
    ),
    exists (
      select 1
        from public.automation_items i
       where i.batch_id = v_item.batch_id
         and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
    ),
    exists (
      select 1
        from public.automation_items i
       where i.batch_id = v_item.batch_id
         and i.status = 'NEEDS_REVIEW'
    )
    into v_has_ready_items, v_has_active_items, v_has_review_items;

  update public.automation_batches b
     set locked_by = case when v_has_ready_items then b.locked_by else null end,
         locked_at = case when v_has_ready_items then b.locked_at else null end,
         lease_expires_at = case when v_has_ready_items then b.lease_expires_at else null end,
         status = case
           when v_has_ready_items then 'RUNNING'::public.automation_status
           when v_has_active_items then 'QUEUED'::public.automation_status
           when v_has_review_items then 'NEEDS_REVIEW'::public.automation_status
           else 'SUCCEEDED'::public.automation_status
         end,
         note = coalesce(b.note, '') || case
           when p_pin_status = 'RECEIVED' then ' | Gmail PIN 已写回；PIN 不写入日志'
           when v_terminal_status = 'QUEUED' then ' | 暂未找到 PIN，5 分钟后重试'
           else ' | Gmail PIN 需人工审核'
         end
   where b.id = v_item.batch_id
     and b.locked_by = p_worker_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    case
      when p_pin_status = 'RECEIVED' then 'GMAIL_PIN_RECEIVED'
      when v_terminal_status = 'QUEUED' then 'GMAIL_PIN_RETRY_SCHEDULED'
      else 'GMAIL_PIN_REVIEW'
    end,
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'pin_status', p_pin_status,
      'pin_value_logged', false,
      'email_body_stored', false,
      'error_code', v_error_code,
      'retry_scheduled', v_next_attempt_at is not null
    )
  );

  select * into v_item from public.automation_items where id = v_item.id;
  return v_item;
end;
$function$
;
create or replace function private.mdac_guard_direct_state() returns trigger
language plpgsql security invoker set search_path='' as $$
declare kind text;
begin
 if current_user in ('postgres','supabase_admin') then return new; end if;
 if tg_table_name='automation_batches' then kind:=new.task_type::text;
 else select task_type::text into kind from public.automation_batches where id=new.batch_id; end if;
 if kind not in ('MDAC_REGISTRATION','REGISTRATION_CHECK','VISIT_PASS_CHECK','GMAIL_PIN') then return new; end if;
 if tg_op='INSERT' then
   if new.status::text<>'QUEUED' or new.locked_by is not null or new.claim_token is not null then
     raise exception 'Worker state must be changed through a fenced RPC' using errcode='42501';
   end if;
 elsif (to_jsonb(new)-array['note','updated_at'])
     is distinct from (to_jsonb(old)-array['note','updated_at']) then
   raise exception 'Worker state must be changed through a fenced RPC' using errcode='42501';
 end if;
 return new;
end $$;

alter table public.ocr_batches add column if not exists locked_by text;
alter table public.ocr_batches add column if not exists locked_at timestamptz;
alter table public.ocr_batches add column if not exists lease_expires_at timestamptz;
alter table public.ocr_batches add column if not exists claim_token uuid;
alter table public.ocr_batches add column if not exists attempt_count integer not null default 0;
alter table public.ocr_batches add column if not exists external_started_at timestamptz;
alter table public.ocr_batches add column if not exists provider_operation_url text;
alter table public.ocr_results add column if not exists claim_token uuid;
create unique index if not exists ocr_results_one_coordinate_v2 on public.ocr_results(batch_id,page_index,segment_index);

create or replace function private.ocr_require_fence(p_worker_id text,p_batch_id uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare h jsonb; b public.ocr_batches;
begin
 h:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
 if h->>'x-mdac-protocol' is distinct from '2' or nullif(trim(p_worker_id),'') is null then
 raise exception 'Fenced OCR protocol v2 is required' using errcode='42501'; end if;
 if p_batch_id is not null then
 select * into b from public.ocr_batches where id=p_batch_id for update;
 if not found or b.status::text<>'PROCESSING' or b.locked_by is distinct from p_worker_id or b.claim_token is null
 or b.claim_token::text is distinct from h->>'x-mdac-batch-token' or b.lease_expires_at is null
 or b.lease_expires_at<=clock_timestamp() then raise exception 'Stale OCR claim rejected' using errcode='42501'; end if;
 end if;
end $$;
revoke all on function private.ocr_require_fence(text,uuid) from public,anon,authenticated,service_role;

create or replace function public.claim_ocr_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5,p_batch_id uuid default null)
returns setof public.ocr_batches language plpgsql security definer set search_path='' as $$
declare b public.ocr_batches;
begin
 perform private.ocr_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.ocr_batches q where (p_batch_id is null or q.id=p_batch_id) and (
 (q.status::text='UPLOADED' and q.attempt_count<p_max_attempts and nullif(q.file_path,'') is not null
 and exists(select 1 from storage.objects o where o.bucket_id='passport-documents' and o.name=q.file_path))
 or (q.status::text='PROCESSING' and q.lease_expires_at<=clock_timestamp()))
 order by q.created_at,q.id limit 1 for update skip locked;
 if not found then return; end if;
 if b.status::text='PROCESSING' then
 update public.ocr_batches set status='FAILED',locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,
 error_message='Lease expired; review provider result before any retry',
 metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('result_unknown',true,'recovery_required',true)
 where id=b.id; return; end if;
 if exists(select 1 from public.ocr_results where batch_id=b.id) then
 update public.ocr_batches set status='REVIEW_REQUIRED',error_message='An OCR result already exists; review it instead of generating another' where id=b.id;
 return; end if;
 update public.ocr_batches set status='PROCESSING',locked_by=p_worker_id,locked_at=clock_timestamp(),
 lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),claim_token=gen_random_uuid(),
 attempt_count=attempt_count+1,error_message=null where id=b.id returning * into b;
 return next b;
end $$;
create or replace function public.heartbeat_ocr_v2(p_worker_id text,p_batch_id uuid default null,p_status public.worker_status default 'ONLINE',p_hostname text default 'local',p_version text default 'ocr-v2',p_lease_seconds integer default 900)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.ocr_require_fence(p_worker_id,case when p_status='BUSY' then p_batch_id else null end);
 if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then raise exception 'Invalid lease bound'; end if;
 if p_status='BUSY' and p_batch_id is not null then update public.ocr_batches
 set locked_at=clock_timestamp(),lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds) where id=p_batch_id; end if;
 insert into public.worker_heartbeats(worker_id,hostname,version,status,current_batch_id,last_seen_at,metadata)
 values(p_worker_id,p_hostname,p_version,p_status,p_batch_id,clock_timestamp(),'{"execution_mode":"AZURE_OCR","claim_protocol":2}')
 on conflict(worker_id) do update set hostname=excluded.hostname,version=excluded.version,status=excluded.status,
 current_batch_id=excluded.current_batch_id,last_seen_at=excluded.last_seen_at,metadata=excluded.metadata;
end $$;
create or replace function public.before_ocr_analyze_v2(p_worker_id text,p_batch_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.ocr_require_fence(p_worker_id,p_batch_id);
 if exists(select 1 from public.ocr_batches where id=p_batch_id and external_started_at is not null) then
 raise exception 'OCR provider submission cannot be repeated'; end if;
 update public.ocr_batches set external_started_at=clock_timestamp() where id=p_batch_id;
end $$;
create or replace function public.record_ocr_operation_v2(p_worker_id text,p_batch_id uuid,p_operation_url text)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.ocr_require_fence(p_worker_id,p_batch_id);
 if p_operation_url not like 'https://%' then raise exception 'Invalid provider operation URL'; end if;
 update public.ocr_batches set provider_operation_url=p_operation_url where id=p_batch_id and provider_operation_url is null;
end $$;
create or replace function public.write_ocr_result_v2(p_worker_id text,p_batch_id uuid,p_payload jsonb)
returns public.ocr_results language plpgsql security definer set search_path='' as $$
declare r public.ocr_results; b public.ocr_batches;
begin
 perform private.ocr_require_fence(p_worker_id,p_batch_id);
 select * into b from public.ocr_batches where id=p_batch_id;
 if b.external_started_at is null then raise exception 'OCR operation has not started'; end if;
 r:=jsonb_populate_record(null::public.ocr_results,p_payload);
 if r.batch_id is distinct from p_batch_id or r.page_index<0 or r.segment_index<0 or r.status::text not in ('REVIEW_REQUIRED','READY_TO_CREATE','FAILED') then raise exception 'Invalid OCR result payload'; end if;
 insert into public.ocr_results(batch_id,page_index,segment_index,raw_result,extracted_data,confidence,status,claim_token)
 values(p_batch_id,r.page_index,r.segment_index,r.raw_result,r.extracted_data,r.confidence,r.status,b.claim_token)
 on conflict(batch_id,page_index,segment_index) do nothing returning * into r;
 if not found then select * into r from public.ocr_results where batch_id=p_batch_id
 and page_index=(p_payload->>'page_index')::integer and segment_index=(p_payload->>'segment_index')::integer;
 if r.claim_token is distinct from b.claim_token then raise exception 'Result belongs to another claim'; end if; end if;
 return r;
end $$;
create or replace function public.update_ocr_batch_v2(p_worker_id text,p_batch_id uuid,p_payload jsonb)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.ocr_require_fence(p_worker_id,p_batch_id);
 if p_payload->>'status' is distinct from 'PROCESSING' then raise exception 'Only initialization is allowed'; end if;
 update public.ocr_batches set total_results=coalesce((p_payload->>'total_results')::integer,total_results),
 processed_results=coalesce((p_payload->>'processed_results')::integer,processed_results) where id=p_batch_id;
end $$;
create or replace function public.finish_ocr_batch(p_worker_id text,p_batch_id uuid,p_payload jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare b public.ocr_batches; target public.ocr_batch_status;
begin
 perform private.ocr_require_fence(p_worker_id,p_batch_id);
 select * into b from public.ocr_batches where id=p_batch_id;
 if p_payload->>'status' not in ('REVIEW_REQUIRED','READY_TO_CREATE','FAILED') then raise exception 'Invalid OCR completion status'; end if;
 target:=(p_payload->>'status')::public.ocr_batch_status;
 if target::text<>'FAILED' and not exists(select 1 from public.ocr_results where batch_id=p_batch_id and claim_token=b.claim_token) then raise exception 'OCR result must be stored before completion'; end if;
 update public.ocr_batches set status=target,
 total_results=coalesce((p_payload->>'total_results')::integer,total_results),
 processed_results=coalesce((p_payload->>'processed_results')::integer,processed_results),
 error_message=left(p_payload->>'error_message',2000),locked_by=null,locked_at=null,lease_expires_at=null,
 metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('result_unknown',target::text='FAILED' and b.external_started_at is not null)
 where id=p_batch_id;
end $$;
create or replace function private.ocr_guard_direct_state() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if current_user in ('postgres','supabase_admin') then return new; end if;
 if tg_table_name='ocr_results' then
   if tg_op='INSERT' then raise exception 'OCR result writes require a fenced RPC' using errcode='42501'; end if;
   return new;
 end if;
 if tg_op='INSERT' and new.status::text='UPLOADED' and new.claim_token is null and new.locked_by is null then return new; end if;
 if tg_op='UPDATE' and old.status::text='UPLOADED' and new.status::text='UPLOADED' and old.claim_token is null
 and new.claim_token is null and new.locked_by is null and new.attempt_count=old.attempt_count
 and (to_jsonb(new)-array['file_path','source_type','metadata','updated_at'])
 is not distinct from (to_jsonb(old)-array['file_path','source_type','metadata','updated_at']) then return new; end if;
 raise exception 'OCR state changes require a fenced RPC' using errcode='42501';
end $$;
revoke all on function private.ocr_guard_direct_state() from public,anon,authenticated;
create trigger ocr_direct_state_guard_v2 before insert or update on public.ocr_batches for each row execute function private.ocr_guard_direct_state();
create trigger ocr_result_insert_guard_v2 before insert on public.ocr_results for each row execute function private.ocr_guard_direct_state();
create or replace function public.mdac_protocol_info_v2() returns jsonb language sql security invoker set search_path='' as $$
 select jsonb_build_object('protocol',2,'max_external_concurrency',1,'gmail_pin_protocol',2,'ocr_protocol',2) $$;

revoke all on function public.claim_ocr_batch(text,integer,integer,uuid) from public,anon,authenticated; grant execute on function public.claim_ocr_batch(text,integer,integer,uuid) to service_role;

revoke all on function public.heartbeat_ocr_v2(text,uuid,public.worker_status,text,text,integer) from public,anon,authenticated; grant execute on function public.heartbeat_ocr_v2(text,uuid,public.worker_status,text,text,integer) to service_role;

revoke all on function public.before_ocr_analyze_v2(text,uuid) from public,anon,authenticated; grant execute on function public.before_ocr_analyze_v2(text,uuid) to service_role;

revoke all on function public.record_ocr_operation_v2(text,uuid,text) from public,anon,authenticated; grant execute on function public.record_ocr_operation_v2(text,uuid,text) to service_role;

revoke all on function public.write_ocr_result_v2(text,uuid,jsonb) from public,anon,authenticated; grant execute on function public.write_ocr_result_v2(text,uuid,jsonb) to service_role;

revoke all on function public.update_ocr_batch_v2(text,uuid,jsonb) from public,anon,authenticated; grant execute on function public.update_ocr_batch_v2(text,uuid,jsonb) to service_role;

revoke all on function public.finish_ocr_batch(text,uuid,jsonb) from public,anon,authenticated; grant execute on function public.finish_ocr_batch(text,uuid,jsonb) to service_role;
notify pgrst,'reload schema';
