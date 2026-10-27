-- Synthetic fixtures in a newly created, dedicated nonproduction schema ONLY.
create schema manual_retry_acceptance_20261028;
grant usage on schema manual_retry_acceptance_20261028 to authenticated,anon,service_role;
create type manual_retry_acceptance_20261028.automation_status as enum
 ('QUEUED','CLAIMED','RUNNING','SUCCEEDED','FAILED','PARTIAL_SUCCESS','NEEDS_REVIEW');
create table manual_retry_acceptance_20261028.profiles (
 id uuid primary key,name text not null,role text not null,is_active boolean not null,
 deleted_at timestamptz,access_mode text not null,access_expires_at timestamptz
);
create table manual_retry_acceptance_20261028.customers(id uuid primary key,
 deleted_at timestamptz,website_archived_at timestamptz);
create table manual_retry_acceptance_20261028.customer_cases(id uuid primary key,
 customer_id uuid not null references manual_retry_acceptance_20261028.customers(id),website_archived_at timestamptz);
create table manual_retry_acceptance_20261028.automation_batches (
 id uuid primary key default gen_random_uuid(), task_type text not null,
 created_by uuid not null references manual_retry_acceptance_20261028.profiles(id),
 status manual_retry_acceptance_20261028.automation_status not null default 'NEEDS_REVIEW',total_count int not null default 0,
 success_count int not null default 0,failed_count int not null default 0,
 attempt_count int not null default 1,locked_by text,locked_at timestamptz,
 lease_expires_at timestamptz,claim_token uuid,entry_date date,exit_date date,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp()
);
create table manual_retry_acceptance_20261028.automation_items (
 id uuid primary key default gen_random_uuid(),batch_id uuid not null references manual_retry_acceptance_20261028.automation_batches(id),
 customer_id uuid not null references manual_retry_acceptance_20261028.customers(id),
 case_id uuid references manual_retry_acceptance_20261028.customer_cases(id),
 customer_snapshot jsonb not null default '{}',status text not null,
 attempt_count int not null default 1,result_unknown boolean not null default false,
 locked_by text,locked_at timestamptz,lease_expires_at timestamptz,claim_token uuid,
 external_started_at timestamptz,submission_started_at timestamptz,
 started_at timestamptz,finished_at timestamptz,next_attempt_at timestamptz,
 error_code text,error_message text,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp()
);
create unique index automation_active_customer_uq on manual_retry_acceptance_20261028.automation_items(customer_id)
 where status in ('QUEUED','CLAIMED','RUNNING');
create table manual_retry_acceptance_20261028.mdac_registrations (
 id uuid primary key default gen_random_uuid(),batch_item_id uuid not null references manual_retry_acceptance_20261028.automation_items(id),
 customer_id uuid references manual_retry_acceptance_20261028.customers(id),
 case_id uuid references manual_retry_acceptance_20261028.customer_cases(id),
 registration_status text not null,submitted_at timestamptz,result_confirmed_at timestamptz,
 registration_no text,raw_summary jsonb not null default '{}'
);
create table manual_retry_acceptance_20261028.email_pin_records (
 id uuid primary key default gen_random_uuid(),batch_item_id uuid not null references manual_retry_acceptance_20261028.automation_items(id),
 status text not null,raw_summary jsonb not null default '{}'
);
create table manual_retry_acceptance_20261028.registration_checks (
 id uuid primary key default gen_random_uuid(),batch_item_id uuid not null references manual_retry_acceptance_20261028.automation_items(id),
 status text not null,raw_summary jsonb not null default '{}'
);
create table manual_retry_acceptance_20261028.visit_pass_checks (
 id uuid primary key default gen_random_uuid(),batch_item_id uuid not null references manual_retry_acceptance_20261028.automation_items(id),
 status text not null,raw_summary jsonb not null default '{}'
);
create table manual_retry_acceptance_20261028.audit_logs (
 id uuid primary key default gen_random_uuid(),actor_id uuid,action text not null,
 entity_type text not null,entity_id uuid,metadata jsonb not null default '{}',
 created_at timestamptz not null default clock_timestamp()
);
create table manual_retry_acceptance_20261028.test_checks (
 name text primary key,passed boolean not null,details jsonb not null default '{}'
);
create table manual_retry_acceptance_20261028.test_context(key text primary key,value jsonb not null);

-- The real production counter and direct-state guard bodies are installed after
-- this fixture by the test generator, with all business references rewritten.
insert into manual_retry_acceptance_20261028.profiles values
 ('11111111-1111-4111-8111-111111111111','SYNTHETIC CREATOR','OPERATOR',true,null,'FULL',null),
 ('22222222-2222-4222-8222-222222222222','SYNTHETIC OTHER OWNER','OWNER',true,null,'FULL',null),
 ('33333333-3333-4333-8333-333333333333','SYNTHETIC INACTIVE','OPERATOR',false,null,'FULL',null),
 ('44444444-4444-4444-8444-444444444444','SYNTHETIC REVIEW','OPERATOR',true,null,'REVIEW_ONLY',null),
 ('55555555-5555-4555-8555-555555555555','SYNTHETIC EXPIRED','OPERATOR',true,null,'FULL','2020-01-01');

-- Fifteen-item batch: 13 immutable successes, one proven pre-submit slider
-- failure, one possible-submit unknown. Every Customer/Case is synthetic.
insert into manual_retry_acceptance_20261028.automation_batches
 (id,task_type,created_by,status,total_count,success_count,attempt_count,entry_date,exit_date)
 values('a1000000-0000-4000-8000-000000000001','MDAC_REGISTRATION',
 '11111111-1111-4111-8111-111111111111','NEEDS_REVIEW',15,13,1,'2035-01-01','2035-01-02');
do $fixture$
declare n int; cid uuid; oid uuid; iid uuid;
begin
 for n in 1..15 loop
  cid:=('b1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
  oid:=('c1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
  iid:=('d1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
  insert into manual_retry_acceptance_20261028.customers values(cid);
  insert into manual_retry_acceptance_20261028.customer_cases values(oid,cid);
  insert into manual_retry_acceptance_20261028.automation_items
   (id,batch_id,customer_id,case_id,customer_snapshot,status,result_unknown,attempt_count,
    external_started_at,submission_started_at,started_at,finished_at,claim_token,error_code,error_message)
   values(iid,'a1000000-0000-4000-8000-000000000001',cid,oid,
    jsonb_build_object('synthetic',true,'ordinal',n),case when n<=13 then 'SUCCEEDED' else 'NEEDS_REVIEW' end,
    n>13,case when n=15 then 2 else 1 end,clock_timestamp(),
    case when n=14 then null else clock_timestamp() end,clock_timestamp(),clock_timestamp(),gen_random_uuid(),
    case when n=14 then 'SLIDER_SOLVER_FAILED' when n=15 then 'FILL_PREVIEW_FAILED' else null end,
    case when n>13 then 'SYNTHETIC ERROR PRESERVED IN HISTORY' else null end);
  insert into manual_retry_acceptance_20261028.mdac_registrations
   (batch_item_id,customer_id,case_id,registration_status,submitted_at,result_confirmed_at,registration_no,raw_summary)
   values(iid,cid,oid,case when n<=13 then 'SUCCEEDED' else 'NEEDS_REVIEW' end,
    case when n=14 then null else clock_timestamp() end,
    case when n<=13 then clock_timestamp() else null end,
    case when n<=13 then 'SYNTHETIC-'||n else null end,
    jsonb_build_object('submitted',n<>14,'result_confirmed',n<=13,
      'slider_solved',n<>14,'execution_mode','AUTO_SUBMIT','synthetic',true));
 end loop;
end $fixture$;
insert into manual_retry_acceptance_20261028.test_context values
 ('success_items', (select jsonb_agg(to_jsonb(i) order by id) from manual_retry_acceptance_20261028.automation_items i where status='SUCCEEDED')),
 ('all_result_rows',(select jsonb_agg(to_jsonb(r) order by id) from manual_retry_acceptance_20261028.mdac_registrations r)),
 ('all_original_items',(select jsonb_agg(to_jsonb(i) order by id) from manual_retry_acceptance_20261028.automation_items i));

-- All records above are generated fixtures, never copied customer data.

CREATE OR REPLACE FUNCTION manual_retry_acceptance_20261028.sync_batch_status_and_counts(p_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_total int; v_success int; v_failed int; v_running int;

  v_queued int; v_review int; v_status manual_retry_acceptance_20261028.automation_status;

begin

  select count(*)::int,

    count(*) filter (where status='SUCCEEDED')::int,

    count(*) filter (where status='FAILED')::int,

    count(*) filter (where status in ('CLAIMED','RUNNING'))::int,

    count(*) filter (where status='QUEUED')::int,

    count(*) filter (where status='NEEDS_REVIEW')::int

  into v_total,v_success,v_failed,v_running,v_queued,v_review

  from manual_retry_acceptance_20261028.automation_items where batch_id=p_batch_id;

  select status into v_status from manual_retry_acceptance_20261028.automation_batches

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

  update manual_retry_acceptance_20261028.automation_batches

  set total_count=v_total,success_count=v_success,failed_count=v_failed,

    status=v_status,updated_at=clock_timestamp() where id=p_batch_id;

end;

$function$
;
CREATE OR REPLACE FUNCTION manual_retry_acceptance_20261028.mdac_guard_direct_state()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

declare kind text;

begin

 if current_user in ('postgres','supabase_admin') then return new; end if;

 if tg_table_name='automation_batches' then kind:=new.task_type::text;

 else select task_type::text into kind from manual_retry_acceptance_20261028.automation_batches where id=new.batch_id; end if;

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

end $function$
;
CREATE OR REPLACE FUNCTION manual_retry_acceptance_20261028.guard_archived_case_work()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_case_id uuid;
  v_customer_id uuid;
  v_locked_customer_id uuid;
  v_customer_archived timestamptz;
  v_case_archived timestamptz;
begin
  if tg_table_name = 'operational_batch_items' then
    v_case_id := new.order_id;
  elsif tg_table_name = 'ocr_results' then
    v_case_id := new.created_case_id;
    v_customer_id := new.created_customer_id;
  else
    v_case_id := new.case_id;
    v_customer_id := new.customer_id;
  end if;

  if v_case_id is not null then
    -- Explicit Customer -> Case order; a join's row-lock order depends on its
    -- plan and may invert archive_order's lock order.
    select cc.customer_id into v_locked_customer_id
      from manual_retry_acceptance_20261028.customer_cases cc where cc.id=v_case_id;
    select c.website_archived_at into v_customer_archived
      from manual_retry_acceptance_20261028.customers c where c.id=v_locked_customer_id for update;
    select cc.website_archived_at,cc.customer_id into v_case_archived,v_customer_id
      from manual_retry_acceptance_20261028.customer_cases cc where cc.id=v_case_id for share;
    if v_customer_id is distinct from v_locked_customer_id then
      raise exception 'Order Customer changed concurrently; retry operation'
        using errcode='40001';
    end if;
    if v_case_archived is not null or v_customer_archived is not null then
      raise exception 'Order/Customer is in Website trash; restore it first'
        using errcode = 'P0001';
    end if;
  elsif v_customer_id is not null then
    select c.website_archived_at into v_customer_archived
      from manual_retry_acceptance_20261028.customers c where c.id = v_customer_id for update;
    if v_customer_archived is not null then
      raise exception 'Customer is in Website trash; restore it first'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end $function$
;
create trigger mdac_direct_state_guard before insert or update on manual_retry_acceptance_20261028.automation_items for each row execute function manual_retry_acceptance_20261028.mdac_guard_direct_state();
create trigger mdac_batch_direct_state_guard before insert or update on manual_retry_acceptance_20261028.automation_batches for each row execute function manual_retry_acceptance_20261028.mdac_guard_direct_state();
create trigger archived_case_automation_guard before insert or update on manual_retry_acceptance_20261028.automation_items for each row execute function manual_retry_acceptance_20261028.guard_archived_case_work();
create trigger archived_case_mdac_guard before insert or update on manual_retry_acceptance_20261028.mdac_registrations for each row execute function manual_retry_acceptance_20261028.guard_archived_case_work();
grant select,update on manual_retry_acceptance_20261028.automation_items,manual_retry_acceptance_20261028.automation_batches to authenticated;
grant select,insert,update on manual_retry_acceptance_20261028.test_checks,manual_retry_acceptance_20261028.test_context to authenticated;
grant select on manual_retry_acceptance_20261028.mdac_registrations to authenticated;

-- Candidate only. Root must generate the migration name with the CLI.
-- No scheduler, polling recovery, Worker rewrite, or automatic enqueue is installed.
-- Existing tables, state guards, RLS policies and ordinary grants are unchanged.
begin;

create table manual_retry_acceptance_20261028.automation_manual_retry_requests (
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
create table manual_retry_acceptance_20261028.automation_manual_retry_history (
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
    references manual_retry_acceptance_20261028.automation_manual_retry_requests(actor_id,request_id)
);
-- No application-table FK: deleting a current result or task must not silently
-- cascade-delete its historical state. An authorized future customer purge must
-- explicitly include these private audit tables under its own retention scope.
alter table manual_retry_acceptance_20261028.automation_manual_retry_requests enable row level security;
alter table manual_retry_acceptance_20261028.automation_manual_retry_history enable row level security;
revoke all on manual_retry_acceptance_20261028.automation_manual_retry_requests,
  manual_retry_acceptance_20261028.automation_manual_retry_history from public,anon,authenticated,service_role;

create function manual_retry_acceptance_20261028.automation_manual_retry_assert_actor(p_actor uuid)
returns void language plpgsql security definer set search_path='' as $fn$
begin
  if coalesce(auth.jwt()->>'role','') <> 'authenticated'
     or p_actor is null or p_actor is distinct from auth.uid() then
    raise exception 'MANUAL_RETRY_AUTHENTICATED_REQUIRED' using errcode='42501';
  end if;
  perform 1 from manual_retry_acceptance_20261028.profiles p where p.id=p_actor and p.is_active
    and p.deleted_at is null and p.access_mode='FULL'
    and (p.access_expires_at is null or p.access_expires_at>clock_timestamp())
    for share;
  if not found then
    raise exception 'MANUAL_RETRY_ACTIVE_FULL_ACCOUNT_REQUIRED' using errcode='42501';
  end if;
end $fn$;

create function manual_retry_acceptance_20261028.automation_manual_retry_state(p_batch_id uuid)
returns jsonb language sql volatile security definer set search_path='' as $fn$
with batch as (
  select b.* from manual_retry_acceptance_20261028.automation_batches b where b.id=p_batch_id
), details as (
  select i.*,b.task_type::text as task_type,
    jsonb_build_object(
      'mdac',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from manual_retry_acceptance_20261028.mdac_registrations r where r.batch_item_id=i.id),'[]'::jsonb),
      'gmail_pin',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from manual_retry_acceptance_20261028.email_pin_records r where r.batch_item_id=i.id),'[]'::jsonb),
      'registration_check',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from manual_retry_acceptance_20261028.registration_checks r where r.batch_item_id=i.id),'[]'::jsonb),
      'visit_pass_check',coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
        from manual_retry_acceptance_20261028.visit_pass_checks r where r.batch_item_id=i.id),'[]'::jsonb)
    ) as result_rows,
    (exists(select 1 from manual_retry_acceptance_20261028.mdac_registrations r where r.batch_item_id=i.id
      and r.registration_status::text='SUCCEEDED')
      or exists(select 1 from manual_retry_acceptance_20261028.audit_logs a where a.entity_id=i.id
        and a.actor_id is null and a.action='MDAC_AUTO_WORKER_SUBMIT'
        and a.metadata->>'status'='SUCCEEDED'))
      as mdac_success,
    exists(select 1 from manual_retry_acceptance_20261028.mdac_registrations r where r.batch_item_id=i.id
      and (r.submitted_at is not null
        or r.registration_status::text in ('SUBMITTED','RESULT_UNKNOWN')
        or r.raw_summary->'submitted'='true'::jsonb))
      or exists(select 1 from manual_retry_acceptance_20261028.audit_logs a where a.entity_id=i.id
        and a.actor_id is null and a.action='MDAC_AUTO_WORKER_SUBMIT'
        and a.metadata->'submitted'='true'::jsonb)
      as submission_evidence,
    exists(select 1 from manual_retry_acceptance_20261028.mdac_registrations r where r.batch_item_id=i.id
      and r.registration_status::text='NEEDS_REVIEW'
      and r.submitted_at is null and r.result_confirmed_at is null
      and nullif(trim(r.registration_no),'') is null
      and r.raw_summary->'submitted'='false'::jsonb
      and r.raw_summary->'result_confirmed'='false'::jsonb
      and r.raw_summary->'slider_solved'='false'::jsonb
      and r.raw_summary->>'execution_mode'='AUTO_SUBMIT'
      and r.raw_summary->'human_in_loop' is distinct from 'true'::jsonb)
      as proven_slider_pre_submit
  from manual_retry_acceptance_20261028.automation_items i join batch b on b.id=i.batch_id
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

create function manual_retry_acceptance_20261028.preview_automation_manual_retry(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_actor uuid:=auth.uid(); v_state jsonb; v_batch manual_retry_acceptance_20261028.automation_batches;
  v_block text; v_total bigint;
begin
  perform manual_retry_acceptance_20261028.automation_manual_retry_assert_actor(v_actor);
  select * into v_batch from manual_retry_acceptance_20261028.automation_batches where id=p_batch_id;
  if not found or v_batch.created_by is distinct from v_actor then
    raise exception 'MANUAL_RETRY_BATCH_NOT_OWNED' using errcode='42501';
  end if;
  if v_batch.task_type::text not in
      ('MDAC_REGISTRATION','REGISTRATION_CHECK','GMAIL_PIN','VISIT_PASS_CHECK') then
    raise exception 'MANUAL_RETRY_UNSUPPORTED_TASK_TYPE' using errcode='22023';
  end if;
  v_state:=manual_retry_acceptance_20261028.automation_manual_retry_state(p_batch_id);
  v_total:=(v_state->>'safe_count')::bigint+(v_state->>'uncertain_count')::bigint;
  if v_batch.attempt_count>=5 then v_block:='ATTEMPT_LIMIT';
  elsif v_batch.status::text in ('QUEUED','CLAIMED','RUNNING')
      or v_batch.lease_expires_at>clock_timestamp()
      or exists(select 1 from manual_retry_acceptance_20261028.automation_items i where i.batch_id=p_batch_id
        and (i.status::text in ('QUEUED','CLAIMED','RUNNING')
          or i.lease_expires_at>clock_timestamp())) then v_block:='ACTIVE_WORK';
  elsif v_total=0 and exists(select 1 from manual_retry_acceptance_20261028.automation_items i
      where i.batch_id=p_batch_id and i.status::text in ('FAILED','NEEDS_REVIEW')
        and i.attempt_count>=5) then v_block:='ATTEMPT_LIMIT';
  elsif exists(select 1 from manual_retry_acceptance_20261028.automation_items i
      join manual_retry_acceptance_20261028.customers c on c.id=i.customer_id
      left join manual_retry_acceptance_20261028.customer_cases cc on cc.id=i.case_id
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

create function manual_retry_acceptance_20261028.request_automation_manual_retry(
  p_batch_id uuid,p_request_id uuid,p_snapshot_token text,
  p_include_uncertain boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_actor uuid:=auth.uid(); v_batch manual_retry_acceptance_20261028.automation_batches;
  v_request manual_retry_acceptance_20261028.automation_manual_retry_requests;
  v_state jsonb; v_customer_ids uuid[]; v_now_customer_ids uuid[];
  v_selected uuid[]; v_safe integer; v_uncertain integer; v_success integer;
  v_response jsonb; v_count integer;
begin
  perform manual_retry_acceptance_20261028.automation_manual_retry_assert_actor(v_actor);
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
    into v_customer_ids from manual_retry_acceptance_20261028.automation_items i where i.batch_id=p_batch_id;
  perform 1 from manual_retry_acceptance_20261028.customers c where c.id=any(v_customer_ids)
    order by c.id for no key update;
  select * into v_batch from manual_retry_acceptance_20261028.automation_batches where id=p_batch_id for update nowait;
  if not found or v_batch.created_by is distinct from v_actor then
    raise exception 'MANUAL_RETRY_BATCH_NOT_OWNED' using errcode='42501';
  end if;
  if v_batch.task_type::text not in
      ('MDAC_REGISTRATION','REGISTRATION_CHECK','GMAIL_PIN','VISIT_PASS_CHECK') then
    raise exception 'MANUAL_RETRY_UNSUPPORTED_TASK_TYPE' using errcode='22023';
  end if;
  perform 1 from manual_retry_acceptance_20261028.automation_items where batch_id=p_batch_id order by id for update nowait;
  -- Lock every existing result before classification/history capture. A concurrent
  -- successful result must either win before this request's snapshot, or wait
  -- until this explicitly accepted retry has committed. Fixed table/id order.
  -- NOWAIT avoids a legacy result writer holding its row while its archive guard
  -- waits for the Customer lock held above; such contention is a safe refresh.
  perform 1 from manual_retry_acceptance_20261028.mdac_registrations r
    where r.batch_item_id in (select id from manual_retry_acceptance_20261028.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  perform 1 from manual_retry_acceptance_20261028.email_pin_records r
    where r.batch_item_id in (select id from manual_retry_acceptance_20261028.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  perform 1 from manual_retry_acceptance_20261028.registration_checks r
    where r.batch_item_id in (select id from manual_retry_acceptance_20261028.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  perform 1 from manual_retry_acceptance_20261028.visit_pass_checks r
    where r.batch_item_id in (select id from manual_retry_acceptance_20261028.automation_items where batch_id=p_batch_id)
    order by r.id for update nowait;
  select array_agg(distinct i.customer_id order by i.customer_id)
    into v_now_customer_ids from manual_retry_acceptance_20261028.automation_items i where i.batch_id=p_batch_id;
  if v_customer_ids is distinct from v_now_customer_ids then
    raise exception 'MANUAL_RETRY_CONTEXT_CHANGED' using errcode='40001';
  end if;
  v_state:=manual_retry_acceptance_20261028.automation_manual_retry_state(p_batch_id);
  select * into v_request from manual_retry_acceptance_20261028.automation_manual_retry_requests
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
      or exists(select 1 from manual_retry_acceptance_20261028.automation_items i where i.batch_id=p_batch_id
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
  if exists(select 1 from manual_retry_acceptance_20261028.automation_items i
      join manual_retry_acceptance_20261028.customers c on c.id=i.customer_id
      left join manual_retry_acceptance_20261028.customer_cases cc on cc.id=i.case_id
      where i.id=any(v_selected) and (c.deleted_at is not null
        or c.website_archived_at is not null or cc.website_archived_at is not null)) then
    raise exception 'MANUAL_RETRY_ARCHIVED_CONTEXT' using errcode='P0001';
  end if;
  if exists(select 1 from manual_retry_acceptance_20261028.automation_items i
      join manual_retry_acceptance_20261028.automation_items other_item on other_item.customer_id=i.customer_id
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
  insert into manual_retry_acceptance_20261028.automation_manual_retry_requests
    (actor_id,request_id,batch_id,snapshot_token,include_uncertain)
    values(v_actor,p_request_id,p_batch_id,p_snapshot_token,p_include_uncertain);
  insert into manual_retry_acceptance_20261028.automation_manual_retry_history
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
  update manual_retry_acceptance_20261028.automation_items set status='QUEUED',result_unknown=false,
    locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,
    external_started_at=null,submission_started_at=null,started_at=null,
    finished_at=null,next_attempt_at=null,error_code=null,error_message=null
    where id=any(v_selected) and status::text in ('FAILED','NEEDS_REVIEW');
  get diagnostics v_count=row_count;
  if v_count is distinct from cardinality(v_selected) then
    raise exception 'MANUAL_RETRY_SELECTION_CHANGED' using errcode='40001';
  end if;
  update manual_retry_acceptance_20261028.automation_batches set locked_by=null,locked_at=null,
    lease_expires_at=null,claim_token=null where id=p_batch_id;
  perform manual_retry_acceptance_20261028.sync_batch_status_and_counts(p_batch_id);
  insert into manual_retry_acceptance_20261028.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values(v_actor,'AUTOMATION_MANUAL_RETRY','automation_batches',p_batch_id,
      jsonb_build_object('request_id',p_request_id,'task_type',v_batch.task_type,
        'include_uncertain',p_include_uncertain,'requeued_count',v_count,
        'successful_items_requeued',0,'attempt_history_preserved',true));
  v_response:=jsonb_build_object('status','QUEUED','task_type',v_batch.task_type::text,
    'requeued_count',v_count,'safe_count',v_safe,'uncertain_count',v_uncertain,
    'excluded_success_count',v_success,'request_id',p_request_id,'replayed',false);
  update manual_retry_acceptance_20261028.automation_manual_retry_requests set response=v_response,
    post_snapshot_token=manual_retry_acceptance_20261028.automation_manual_retry_state(p_batch_id)->>'snapshot_token'
    where actor_id=v_actor and request_id=p_request_id;
  return v_response;
exception when lock_not_available then
  raise exception 'MANUAL_RETRY_CONCURRENT_WRITE_REFRESH' using errcode='40001';
end $fn$;

revoke all on function manual_retry_acceptance_20261028.automation_manual_retry_assert_actor(uuid),
  manual_retry_acceptance_20261028.automation_manual_retry_state(uuid) from public,anon,authenticated,service_role;
revoke all on function manual_retry_acceptance_20261028.preview_automation_manual_retry(uuid),
  manual_retry_acceptance_20261028.request_automation_manual_retry(uuid,uuid,text,boolean)
  from public,anon,authenticated,service_role;
grant execute on function manual_retry_acceptance_20261028.preview_automation_manual_retry(uuid),
  manual_retry_acceptance_20261028.request_automation_manual_retry(uuid,uuid,text,boolean) to authenticated;
commit;
