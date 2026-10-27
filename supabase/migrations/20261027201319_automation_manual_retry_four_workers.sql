-- Candidate only. Root must generate the migration name with the CLI.
-- No scheduler, polling recovery, Worker rewrite, or automatic enqueue is installed.
-- Existing tables, state guards, RLS policies and ordinary grants are unchanged.
begin;

create table private.automation_manual_retry_requests (
  actor_id uuid not null,
  request_id uuid not null,
  batch_id uuid not null,
  snapshot_token text not null,
  include_uncertain boolean not null,
  post_snapshot_token text,
  response jsonb,
  created_at timestamptz not null default clock_timestamp(),
  primary key (actor_id, request_id)
);
create table private.automation_manual_retry_history (
  actor_id uuid not null,
  request_id uuid not null,
  batch_id uuid not null,
  item_id uuid not null,
  customer_id uuid not null,
  case_id uuid,
  attempt_count integer not null,
  risk_class text not null check (risk_class in ('SAFE','UNCERTAIN')),
  uncertain_reexecution_confirmed boolean not null,
  before_item jsonb not null,
  before_batch_state jsonb not null,
  before_results jsonb not null,
  recorded_at timestamptz not null default clock_timestamp(),
  primary key (actor_id, request_id, item_id),
  foreign key (actor_id, request_id)
    references private.automation_manual_retry_requests(actor_id,request_id)
);
-- No application-table FK: deleting a current result or task must not silently
-- cascade-delete its historical state. An authorized future customer purge must
-- explicitly include these private audit tables under its own retention scope.
alter table private.automation_manual_retry_requests enable row level security;
alter table private.automation_manual_retry_history enable row level security;
revoke all on private.automation_manual_retry_requests,
  private.automation_manual_retry_history from public,anon,authenticated,service_role;

create function private.automation_manual_retry_assert_actor(p_actor uuid)
returns void language plpgsql security definer set search_path='' as $fn$
begin
  if coalesce(auth.jwt()->>'role','') <> 'authenticated'
     or p_actor is null or p_actor is distinct from auth.uid() then
    raise exception 'MANUAL_RETRY_AUTHENTICATED_REQUIRED' using errcode='42501';
  end if;
  perform 1 from public.profiles p where p.id=p_actor and p.is_active
    and p.deleted_at is null and p.access_mode='FULL'
    and (p.access_expires_at is null or p.access_expires_at>clock_timestamp())
    for share;
  if not found then
    raise exception 'MANUAL_RETRY_ACTIVE_FULL_ACCOUNT_REQUIRED' using errcode='42501';
  end if;
end $fn$;

create function private.automation_manual_retry_state(p_batch_id uuid)
returns jsonb language sql volatile security definer set search_path='' as $fn$
with batch as (
  select b.* from public.automation_batches b where b.id=p_batch_id
), details as (
  select i.*,b.task_type::text as task_type,
    jsonb_build_object(
      'mdac',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from public.mdac_registrations r where r.batch_item_id=i.id),'[]'::jsonb),
      'gmail_pin',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from public.email_pin_records r where r.batch_item_id=i.id),'[]'::jsonb),
      'registration_check',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from public.registration_checks r where r.batch_item_id=i.id),'[]'::jsonb),
      'visit_pass_check',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from public.visit_pass_checks r where r.batch_item_id=i.id),'[]'::jsonb)
    ) as result_rows,
    (exists(select 1 from public.mdac_registrations r where r.batch_item_id=i.id
      and r.registration_status::text='SUCCEEDED')
      or exists(select 1 from public.audit_logs a where a.entity_id=i.id
        and a.actor_id is null and a.action='MDAC_AUTO_WORKER_SUBMIT'
        and a.metadata->>'status'='SUCCEEDED'))
      as mdac_success,
    exists(select 1 from public.mdac_registrations r where r.batch_item_id=i.id
      and (r.submitted_at is not null
        or r.registration_status::text in ('SUBMITTED','RESULT_UNKNOWN')
        or r.raw_summary->'submitted'='true'::jsonb))
      or exists(select 1 from public.audit_logs a where a.entity_id=i.id
        and a.actor_id is null and a.action='MDAC_AUTO_WORKER_SUBMIT'
        and a.metadata->'submitted'='true'::jsonb)
      as submission_evidence,
    exists(select 1 from public.mdac_registrations r where r.batch_item_id=i.id
      and r.registration_status::text='NEEDS_REVIEW'
      and r.submitted_at is null and r.result_confirmed_at is null
      and nullif(trim(r.registration_no),'') is null
      and r.raw_summary->'submitted'='false'::jsonb
      and r.raw_summary->'result_confirmed'='false'::jsonb
      and r.raw_summary->'slider_solved'='false'::jsonb
      and r.raw_summary->>'execution_mode'='AUTO_SUBMIT'
      and r.raw_summary->'human_in_loop' is distinct from 'true'::jsonb)
      as proven_slider_pre_submit
  from public.automation_items i join batch b on b.id=i.batch_id
), classified as (
  select d.*,case
    when d.status::text='SUCCEEDED' or (d.task_type='MDAC_REGISTRATION' and d.mdac_success)
      then 'SUCCESS'
    when d.status::text not in ('FAILED','NEEDS_REVIEW') or d.attempt_count>=5
      then 'INELIGIBLE'
    -- These three Worker types read/query. Repeating their user-requested work
    -- does not submit an MDAC registration. Their old query flags stay in history.
    when d.task_type in ('GMAIL_PIN','REGISTRATION_CHECK','VISIT_PASS_CHECK') then 'SAFE'
    when d.submission_started_at is not null or d.submission_evidence then 'UNCERTAIN'
    when not d.result_unknown then 'SAFE'
    when d.error_code='SLIDER_SOLVER_FAILED' and d.proven_slider_pre_submit then 'SAFE'
    else 'UNCERTAIN' end as risk_class
  from details d
), document as (
  select jsonb_build_object('batch',to_jsonb(b),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'item',to_jsonb(c)-array['task_type','result_rows','mdac_success',
        'submission_evidence','proven_slider_pre_submit','risk_class'],
      'risk_class',c.risk_class,'results',c.result_rows) order by c.id)
      from classified c),'[]'::jsonb)) as body
  from batch b
)
select body || jsonb_build_object('snapshot_token',md5(body::text),
  'safe_count',(select count(*) from classified where risk_class='SAFE'),
  'uncertain_count',(select count(*) from classified where risk_class='UNCERTAIN'),
  'excluded_success_count',(select count(*) from classified where risk_class='SUCCESS'),
  'ineligible_count',(select count(*) from classified where risk_class='INELIGIBLE'))
from document
$fn$;

create function public.preview_automation_manual_retry(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_actor uuid:=auth.uid(); v_state jsonb; v_batch public.automation_batches;
  v_block text; v_total bigint;
begin
  perform private.automation_manual_retry_assert_actor(v_actor);
  select * into v_batch from public.automation_batches where id=p_batch_id;
  if not found or v_batch.created_by is distinct from v_actor then
    raise exception 'MANUAL_RETRY_BATCH_NOT_OWNED' using errcode='42501';
  end if;
  if v_batch.task_type::text not in
      ('MDAC_REGISTRATION','REGISTRATION_CHECK','GMAIL_PIN','VISIT_PASS_CHECK') then
    raise exception 'MANUAL_RETRY_UNSUPPORTED_TASK_TYPE' using errcode='22023';
  end if;
  v_state:=private.automation_manual_retry_state(p_batch_id);
  v_total:=(v_state->>'safe_count')::bigint+(v_state->>'uncertain_count')::bigint;
  if v_batch.attempt_count>=5 then v_block:='ATTEMPT_LIMIT';
  elsif v_batch.status::text in ('QUEUED','CLAIMED','RUNNING')
      or v_batch.lease_expires_at>clock_timestamp()
      or exists(select 1 from public.automation_items i where i.batch_id=p_batch_id
        and (i.status::text in ('QUEUED','CLAIMED','RUNNING')
          or i.lease_expires_at>clock_timestamp())) then v_block:='ACTIVE_WORK';
  elsif v_total=0 and exists(select 1 from public.automation_items i
      where i.batch_id=p_batch_id and i.status::text in ('FAILED','NEEDS_REVIEW')
        and i.attempt_count>=5) then v_block:='ATTEMPT_LIMIT';
  elsif exists(select 1 from public.automation_items i
      join public.customers c on c.id=i.customer_id
      left join public.customer_cases cc on cc.id=i.case_id
      where i.batch_id=p_batch_id and i.status::text in ('FAILED','NEEDS_REVIEW')
        and (c.deleted_at is not null or c.website_archived_at is not null
          or cc.website_archived_at is not null)) then v_block:='ARCHIVED_CONTEXT';
  end if;
  return jsonb_build_object('status',case when v_block is not null then 'BLOCKED'
      when v_total=0 then 'EMPTY' else 'READY' end,
    'task_type',v_batch.task_type::text,
    'snapshot_token',v_state->>'snapshot_token',
    'safe_count',(v_state->>'safe_count')::integer,
    'uncertain_count',(v_state->>'uncertain_count')::integer,
    'excluded_success_count',(v_state->>'excluded_success_count')::integer,
    'ineligible_count',(v_state->>'ineligible_count')::integer,
    'requeued_count',0,'request_id',null,'replayed',false,'blocked_reason',v_block);
end $fn$;

create function public.request_automation_manual_retry(
  p_batch_id uuid,p_request_id uuid,p_snapshot_token text,
  p_include_uncertain boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_actor uuid:=auth.uid(); v_batch public.automation_batches;
  v_request private.automation_manual_retry_requests;
  v_state jsonb; v_customer_ids uuid[]; v_now_customer_ids uuid[];
  v_selected uuid[]; v_safe integer; v_uncertain integer; v_success integer;
  v_response jsonb; v_count integer;
begin
  perform private.automation_manual_retry_assert_actor(v_actor);
  if p_request_id is null or p_snapshot_token is null
      or p_snapshot_token!~'^[a-f0-9]{32}$' or p_include_uncertain is null then
    raise exception 'MANUAL_RETRY_INVALID_REQUEST' using errcode='22023';
  end if;
  -- Serialize the same actor/request UUID even when a mistaken caller reuses it
  -- for another batch. This lock does not authorize the caller or replace row locks.
  perform pg_advisory_xact_lock(hashtextextended(
    'manual-retry:'||v_actor::text||':'||p_request_id::text,0));
  -- Customer locks precede batch/item locks, always in UUID order. NO KEY UPDATE
  -- serializes competing enqueue checks without conflicting with FK KEY SHARE
  -- reads made by a finishing Worker already holding its parent-batch lock.
  select array_agg(distinct i.customer_id order by i.customer_id)
    into v_customer_ids from public.automation_items i where i.batch_id=p_batch_id;
  perform 1 from public.customers c where c.id=any(v_customer_ids)
    order by c.id for no key update;
  select * into v_batch from public.automation_batches where id=p_batch_id for update nowait;
  if not found or v_batch.created_by is distinct from v_actor then
    raise exception 'MANUAL_RETRY_BATCH_NOT_OWNED' using errcode='42501';
  end if;
  if v_batch.task_type::text not in
      ('MDAC_REGISTRATION','REGISTRATION_CHECK','GMAIL_PIN','VISIT_PASS_CHECK') then
    raise exception 'MANUAL_RETRY_UNSUPPORTED_TASK_TYPE' using errcode='22023';
  end if;
  perform 1 from public.automation_items where batch_id=p_batch_id order by id for update nowait;
  -- Lock every existing result before classification/history capture. A concurrent
  -- successful result must either win before this request's snapshot, or wait
  -- until this explicitly accepted retry has committed. Fixed table/id order.
  -- NOWAIT avoids a legacy result writer holding its row while its archive guard
  -- waits for the Customer lock held above; such contention is a safe refresh.
  perform 1 from public.mdac_registrations r
    where r.batch_item_id in (select id from public.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  perform 1 from public.email_pin_records r
    where r.batch_item_id in (select id from public.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  perform 1 from public.registration_checks r
    where r.batch_item_id in (select id from public.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  perform 1 from public.visit_pass_checks r
    where r.batch_item_id in (select id from public.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  select array_agg(distinct i.customer_id order by i.customer_id)
    into v_now_customer_ids from public.automation_items i where i.batch_id=p_batch_id;
  if v_customer_ids is distinct from v_now_customer_ids then
    raise exception 'MANUAL_RETRY_CONTEXT_CHANGED' using errcode='40001';
  end if;
  v_state:=private.automation_manual_retry_state(p_batch_id);
  select * into v_request from private.automation_manual_retry_requests
    where actor_id=v_actor and request_id=p_request_id for update;
  if found then
    if v_request.batch_id is distinct from p_batch_id
        or v_request.snapshot_token is distinct from p_snapshot_token
        or v_request.include_uncertain is distinct from p_include_uncertain then
      raise exception 'MANUAL_RETRY_REQUEST_ID_REUSED' using errcode='22023';
    end if;
    if v_request.response is null or v_request.post_snapshot_token is distinct from
        v_state->>'snapshot_token' then
      raise exception 'MANUAL_RETRY_ALREADY_ADVANCED' using errcode='40001';
    end if;
    return v_request.response || jsonb_build_object('replayed',true);
  end if;
  if p_snapshot_token is distinct from v_state->>'snapshot_token' then
    raise exception 'MANUAL_RETRY_SNAPSHOT_CHANGED' using errcode='40001';
  end if;
  if v_batch.attempt_count>=5 then
    raise exception 'MANUAL_RETRY_ATTEMPT_LIMIT' using errcode='P0001';
  end if;
  if v_batch.status::text in ('QUEUED','CLAIMED','RUNNING')
      or v_batch.lease_expires_at>clock_timestamp()
      or exists(select 1 from public.automation_items i where i.batch_id=p_batch_id
        and (i.status::text in ('QUEUED','CLAIMED','RUNNING')
          or i.lease_expires_at>clock_timestamp())) then
    raise exception 'MANUAL_RETRY_ACTIVE_WORK' using errcode='P0001';
  end if;
  v_safe:=(v_state->>'safe_count')::integer;
  v_uncertain:=(v_state->>'uncertain_count')::integer;
  v_success:=(v_state->>'excluded_success_count')::integer;
  select array_agg((x->'item'->>'id')::uuid order by x->'item'->>'id')
    into v_selected from jsonb_array_elements(v_state->'items') x
    where x->>'risk_class'='SAFE'
      or (p_include_uncertain and x->>'risk_class'='UNCERTAIN');
  if coalesce(cardinality(v_selected),0)=0 then
    if not p_include_uncertain and v_uncertain>0 then
      raise exception 'MANUAL_RETRY_EXPLICIT_CONFIRMATION_REQUIRED' using errcode='P0001';
    end if;
    raise exception 'MANUAL_RETRY_NO_ELIGIBLE_ITEMS' using errcode='P0001';
  end if;
  if exists(select 1 from public.automation_items i
      join public.customers c on c.id=i.customer_id
      left join public.customer_cases cc on cc.id=i.case_id
      where i.id=any(v_selected) and (c.deleted_at is not null
        or c.website_archived_at is not null or cc.website_archived_at is not null)) then
    raise exception 'MANUAL_RETRY_ARCHIVED_CONTEXT' using errcode='P0001';
  end if;
  if exists(select 1 from public.automation_items i
      join public.automation_items other_item on other_item.customer_id=i.customer_id
        and other_item.id<>i.id
      where i.id=any(v_selected) and
        (other_item.status::text in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')
          or other_item.result_unknown
          or (other_item.submission_started_at is not null
            and other_item.status::text<>'SUCCEEDED'))) then
    raise exception 'MANUAL_RETRY_CUSTOMER_OVERLAP' using errcode='P0001';
  end if;
  -- The existing active-customer unique index remains the atomic backstop for
  -- competing legacy callers that do not participate in Customer row locking.
  insert into private.automation_manual_retry_requests
    (actor_id,request_id,batch_id,snapshot_token,include_uncertain)
    values(v_actor,p_request_id,p_batch_id,p_snapshot_token,p_include_uncertain);
  insert into private.automation_manual_retry_history
    (actor_id,request_id,batch_id,item_id,customer_id,case_id,attempt_count,
      risk_class,uncertain_reexecution_confirmed,before_item,before_batch_state,before_results)
    select v_actor,p_request_id,p_batch_id,(x->'item'->>'id')::uuid,
      (x->'item'->>'customer_id')::uuid,(x->'item'->>'case_id')::uuid,
      (x->'item'->>'attempt_count')::integer,x->>'risk_class',
      p_include_uncertain and x->>'risk_class'='UNCERTAIN',x->'item',
      jsonb_build_object('id',v_batch.id,'created_by',v_batch.created_by,
        'task_type',v_batch.task_type,'status',v_batch.status,
        'attempt_count',v_batch.attempt_count,'claim_token',v_batch.claim_token,
        'locked_by',v_batch.locked_by,'locked_at',v_batch.locked_at,
        'lease_expires_at',v_batch.lease_expires_at,'updated_at',v_batch.updated_at),
      x->'results'
    from jsonb_array_elements(v_state->'items') x
    where (x->'item'->>'id')::uuid=any(v_selected);
  -- Never alter identity, ownership, current result rows, or attempt_count.
  -- The old state, including all uncertainty/submission markers and errors,
  -- already exists in append-only restricted history before these fields reset.
  update public.automation_items set status='QUEUED',result_unknown=false,
    locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,
    external_started_at=null,submission_started_at=null,started_at=null,
    finished_at=null,next_attempt_at=null,error_code=null,error_message=null
    where id=any(v_selected) and status::text in ('FAILED','NEEDS_REVIEW');
  get diagnostics v_count=row_count;
  if v_count is distinct from cardinality(v_selected) then
    raise exception 'MANUAL_RETRY_SELECTION_CHANGED' using errcode='40001';
  end if;
  update public.automation_batches set locked_by=null,locked_at=null,
    lease_expires_at=null,claim_token=null where id=p_batch_id;
  perform private.sync_batch_status_and_counts(p_batch_id);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values(v_actor,'AUTOMATION_MANUAL_RETRY','automation_batches',p_batch_id,
      jsonb_build_object('request_id',p_request_id,'task_type',v_batch.task_type,
        'include_uncertain',p_include_uncertain,'requeued_count',v_count,
        'successful_items_requeued',0,'attempt_history_preserved',true));
  v_response:=jsonb_build_object('status','QUEUED','task_type',v_batch.task_type::text,
    'requeued_count',v_count,'safe_count',v_safe,'uncertain_count',v_uncertain,
    'excluded_success_count',v_success,'request_id',p_request_id,'replayed',false);
  update private.automation_manual_retry_requests set response=v_response,
    post_snapshot_token=private.automation_manual_retry_state(p_batch_id)->>'snapshot_token'
    where actor_id=v_actor and request_id=p_request_id;
  return v_response;
exception when lock_not_available then
  raise exception 'MANUAL_RETRY_CONCURRENT_WRITE_REFRESH' using errcode='40001';
end $fn$;

revoke all on function private.automation_manual_retry_assert_actor(uuid),
  private.automation_manual_retry_state(uuid) from public,anon,authenticated,service_role;
revoke all on function public.preview_automation_manual_retry(uuid),
  public.request_automation_manual_retry(uuid,uuid,text,boolean)
  from public,anon,authenticated,service_role;
grant execute on function public.preview_automation_manual_retry(uuid),
  public.request_automation_manual_retry(uuid,uuid,text,boolean) to authenticated;
commit;
