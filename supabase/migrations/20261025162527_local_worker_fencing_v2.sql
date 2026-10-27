
-- Requires matching fenced local clients. No customer/task rows are deleted or reset.
lock table public.automation_batches, public.automation_items in access exclusive mode;
do $$ begin
 if exists (select 1 from public.automation_items i join public.automation_batches b on b.id=i.batch_id
   where b.task_type::text in ('MDAC_REGISTRATION','REGISTRATION_CHECK','VISIT_PASS_CHECK')
   and i.status::text in ('CLAIMED','RUNNING')) then
   raise exception 'Active browser tasks exist; drain before installing protocol v2';
 end if;
end $$;
alter table public.automation_batches add column if not exists claim_token uuid;
alter table public.automation_items add column if not exists claim_token uuid;
alter table public.automation_items add column if not exists external_started_at timestamptz;
alter table public.automation_items add column if not exists submission_started_at timestamptz;

create or replace function private.mdac_require_fence(p_worker_id text,p_batch_id uuid default null,p_item_id uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare h jsonb; b public.automation_batches; i public.automation_items; bid uuid;
begin
 h := coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
 if h->>'x-mdac-protocol' is distinct from '2' then raise exception 'Fenced Worker protocol v2 is required' using errcode='42501'; end if;
 if nullif(trim(p_worker_id),'') is null then raise exception 'Worker id is required'; end if;
 bid:=p_batch_id;
 if p_item_id is not null then select batch_id into bid from public.automation_items where id=p_item_id; end if;
 if bid is not null then
   select * into b from public.automation_batches where id=bid for update;
   if not found or b.locked_by is distinct from p_worker_id or b.claim_token is null
      or b.claim_token::text is distinct from h->>'x-mdac-batch-token'
      or b.lease_expires_at is null or b.lease_expires_at<=clock_timestamp() then
      raise exception 'Stale batch claim rejected' using errcode='42501';
   end if;
 end if;
 if p_item_id is not null then
   select * into i from public.automation_items where id=p_item_id for update;
   if not found or i.locked_by is distinct from p_worker_id or i.claim_token is null
      or i.claim_token::text is distinct from h->>'x-mdac-item-token'
      or i.lease_expires_at is null or i.lease_expires_at<=clock_timestamp()
      or i.status::text not in ('CLAIMED','RUNNING') then
      raise exception 'Stale item claim rejected' using errcode='42501';
   end if;
 end if;
end $$;
revoke all on function private.mdac_require_fence(text,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function private.mdac_guard_direct_state() returns trigger
language plpgsql security invoker set search_path='' as $$
declare kind text;
begin
 if current_user in ('postgres','supabase_admin') then return new; end if;
 if tg_table_name='automation_batches' then kind:=new.task_type::text;
 else select task_type::text into kind from public.automation_batches where id=new.batch_id; end if;
 if kind not in ('MDAC_REGISTRATION','REGISTRATION_CHECK','VISIT_PASS_CHECK') then return new; end if;
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
revoke all on function private.mdac_guard_direct_state() from public,anon,authenticated;
drop trigger if exists mdac_direct_state_guard_v2 on public.automation_batches;
create trigger mdac_direct_state_guard_v2 before insert or update on public.automation_batches
for each row execute function private.mdac_guard_direct_state();
drop trigger if exists mdac_direct_state_guard_v2 on public.automation_items;
create trigger mdac_direct_state_guard_v2 before insert or update on public.automation_items
for each row execute function private.mdac_guard_direct_state();

create or replace function public.claim_mdac_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='MDAC_REGISTRATION'
 and q.attempt_count<p_max_attempts and (
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
revoke all on function public.claim_mdac_batch(text,integer,integer) from public,anon,authenticated;
grant execute on function public.claim_mdac_batch(text,integer,integer) to service_role;

create or replace function public.claim_mdac_item(p_batch_id uuid,p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_items language plpgsql security definer set search_path='' as $$
declare i public.automation_items;
begin
 perform private.mdac_require_fence(p_worker_id,p_batch_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 if not exists(select 1 from public.automation_batches where id=p_batch_id and task_type::text='MDAC_REGISTRATION') then raise exception 'Wrong task type'; end if;
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
revoke all on function public.claim_mdac_item(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.claim_mdac_item(uuid,text,integer,integer) to service_role;

create or replace function public.claim_registration_check_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='REGISTRATION_CHECK'
 and q.attempt_count<p_max_attempts and (
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
revoke all on function public.claim_registration_check_batch(text,integer,integer) from public,anon,authenticated;
grant execute on function public.claim_registration_check_batch(text,integer,integer) to service_role;

create or replace function public.claim_registration_check_item(p_batch_id uuid,p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_items language plpgsql security definer set search_path='' as $$
declare i public.automation_items;
begin
 perform private.mdac_require_fence(p_worker_id,p_batch_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 if not exists(select 1 from public.automation_batches where id=p_batch_id and task_type::text='REGISTRATION_CHECK') then raise exception 'Wrong task type'; end if;
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
revoke all on function public.claim_registration_check_item(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.claim_registration_check_item(uuid,text,integer,integer) to service_role;

create or replace function public.claim_visit_pass_check_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='VISIT_PASS_CHECK'
 and q.attempt_count<p_max_attempts and (
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
revoke all on function public.claim_visit_pass_check_batch(text,integer,integer) from public,anon,authenticated;
grant execute on function public.claim_visit_pass_check_batch(text,integer,integer) to service_role;

create or replace function public.claim_visit_pass_check_item(p_batch_id uuid,p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_items language plpgsql security definer set search_path='' as $$
declare i public.automation_items;
begin
 perform private.mdac_require_fence(p_worker_id,p_batch_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 if not exists(select 1 from public.automation_batches where id=p_batch_id and task_type::text='VISIT_PASS_CHECK') then raise exception 'Wrong task type'; end if;
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
revoke all on function public.claim_visit_pass_check_item(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.claim_visit_pass_check_item(uuid,text,integer,integer) to service_role;

CREATE OR REPLACE FUNCTION public.heartbeat_mdac(p_worker_id text, p_batch_id uuid DEFAULT NULL::uuid, p_item_id uuid DEFAULT NULL::uuid, p_lease_seconds integer DEFAULT 900, p_status worker_status DEFAULT 'ONLINE'::worker_status, p_hostname text DEFAULT 'railway'::text, p_version text DEFAULT 'mdac-fill-preview'::text)
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
    coalesce(nullif(trim(p_version), ''), 'mdac-fill-preview'),
    p_status,
    case when p_status = 'BUSY' then p_batch_id else null end,
    v_now,
    jsonb_build_object('execution_mode', 'FILL_PREVIEW', 'submitted', false)
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

CREATE OR REPLACE FUNCTION public.heartbeat_registration_check(p_worker_id text, p_batch_id uuid DEFAULT NULL::uuid, p_item_id uuid DEFAULT NULL::uuid, p_lease_seconds integer DEFAULT 900, p_status worker_status DEFAULT 'ONLINE'::worker_status, p_hostname text DEFAULT 'railway'::text, p_version text DEFAULT 'registration-check-1'::text)
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
    coalesce(nullif(trim(p_version), ''), 'registration-check-1'),
    p_status,
    case when p_status = 'BUSY' then p_batch_id else null end,
    v_now,
    jsonb_build_object(
      'execution_mode', 'REGISTRATION_CHECK',
      'captcha_bypass', false,
      'submitted', false,
      'result_confirmed', false
    )
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
     where id = p_batch_id and locked_by = p_worker_id;
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

CREATE OR REPLACE FUNCTION public.heartbeat_visit_pass_check(p_worker_id text, p_batch_id uuid DEFAULT NULL::uuid, p_item_id uuid DEFAULT NULL::uuid, p_lease_seconds integer DEFAULT 900, p_status worker_status DEFAULT 'ONLINE'::worker_status, p_hostname text DEFAULT 'railway'::text, p_version text DEFAULT 'visit-pass-check-1'::text)
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
    coalesce(nullif(trim(p_version), ''), 'visit-pass-check-1'),
    p_status,
    case when p_status = 'BUSY' then p_batch_id else null end,
    v_now,
    jsonb_build_object(
      'execution_mode', 'VISIT_PASS_CHECK',
      'captcha_bypass', false,
      'submitted', false,
      'result_confirmed', false
    )
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
     where id = p_batch_id and locked_by = p_worker_id;
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

CREATE OR REPLACE FUNCTION public.finish_mdac_registration_worker(p_item_id uuid, p_worker_id text, p_status text, p_registration_number text DEFAULT NULL::text, p_screenshot_path text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text, p_registration_no text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_now timestamptz := now();
  v_status text := upper(trim(coalesce(p_status, 'NEEDS_REVIEW')));
  v_item_status public.automation_item_status;
  v_reg_status public.registration_status;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_summary jsonb;
  v_has_more boolean;
  v_reg_number text := coalesce(nullif(trim(p_registration_number), ''), nullif(trim(p_registration_no), ''));
begin
  perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_status not in ('SUCCEEDED', 'NEEDS_REVIEW', 'FAILED') then
    raise exception 'invalid finish status: %', v_status;
  end if;

  select *
    into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
   for update;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select *
    into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent batch not found';
  end if;

  if v_status = 'SUCCEEDED' then
    v_item_status := 'SUCCEEDED';
    v_reg_status := 'SUCCEEDED';
    v_error_code := null;
    v_error_message := null;
  elsif v_status = 'FAILED' then
    v_item_status := 'FAILED';
    v_reg_status := 'FAILED';
    v_error_code := coalesce(p_error_code, 'MDAC_REGISTRATION_FAILED');
    v_error_message := coalesce(p_error_message, 'MDAC 官方注册失败');
  else
    v_item_status := 'NEEDS_REVIEW';
    v_reg_status := 'NEEDS_REVIEW';
    v_error_code := coalesce(p_error_code, 'NEEDS_HUMAN_INTERVENTION');
    v_error_message := coalesce(p_error_message, '需要人工核对/提交');
  end if;

  v_summary := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'auto_worker', true,
      'submitted', (v_status = 'SUCCEEDED'),
      'result_confirmed', (v_status = 'SUCCEEDED'),
      'completed_at', v_now
    );

  update public.automation_items
     set status = v_item_status,
         finished_at = case when v_item_status = 'NEEDS_REVIEW' then null else v_now end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = (v_item_status = 'NEEDS_REVIEW')
   where id = v_item.id
  returning * into v_item;

  insert into public.mdac_registrations (
    customer_id,
    batch_item_id,
    entry_date,
    exit_date,
    registration_no,
    registration_status,
    raw_summary,
    screenshot_path,
    submitted_at,
    result_confirmed_at
  ) values (
    v_item.customer_id,
    v_item.id,
    v_batch.entry_date,
    v_batch.exit_date,
    v_reg_number,
    v_reg_status,
    v_summary,
    nullif(trim(p_screenshot_path), ''),
    case when v_status = 'SUCCEEDED' then v_now else null end,
    case when v_status = 'SUCCEEDED' then v_now else null end
  )
  on conflict (batch_item_id) do update set
    entry_date = excluded.entry_date,
    exit_date = excluded.exit_date,
    registration_no = coalesce(excluded.registration_no, mdac_registrations.registration_no),
    registration_status = excluded.registration_status,
    raw_summary = excluded.raw_summary,
    screenshot_path = coalesce(excluded.screenshot_path, mdac_registrations.screenshot_path),
    submitted_at = case when v_status = 'SUCCEEDED' then v_now else mdac_registrations.submitted_at end,
    result_confirmed_at = case when v_status = 'SUCCEEDED' then v_now else mdac_registrations.result_confirmed_at end,
    updated_at = v_now;

  if v_status = 'SUCCEEDED' then
    update public.customers
       set business_status = 'MDAC_REGISTERED',
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  elsif v_status = 'FAILED' then
    update public.customers
       set business_status = 'ACTION_REQUIRED',
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  end if;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'MDAC_AUTO_WORKER_SUBMIT',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_batch.id,
      'customer_id', v_item.customer_id,
      'worker_id', p_worker_id,
      'status', v_status,
      'registration_number', v_reg_number
    )
  );

  select exists (
    select 1 from public.automation_items i
     where i.batch_id = v_item.batch_id
       and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
  ) into v_has_more;

  update public.automation_batches b
     set locked_by = case when v_has_more then b.locked_by else null end,
         locked_at = case when v_has_more then b.locked_at else null end,
         lease_expires_at = case when v_has_more then now() + interval '15 minutes' else null end,
         success_count = (
           select count(*) from public.automation_items i
            where i.batch_id = b.id and i.status in ('SUCCEEDED', 'NEEDS_REVIEW')
         ),
         failed_count = (
           select count(*) from public.automation_items i
            where i.batch_id = b.id and i.status = 'FAILED'
         ),
         status = case
           when not v_has_more then case
             when exists (
               select 1 from public.automation_items i
                where i.batch_id = b.id and i.status = 'FAILED'
             ) then 'FAILED'::public.automation_status
             when exists (
               select 1 from public.automation_items i
                where i.batch_id = b.id and i.status = 'NEEDS_REVIEW'
             ) then 'NEEDS_REVIEW'::public.automation_status
             else 'SUCCEEDED'::public.automation_status
           end
           else b.status
         end,
         updated_at = now()
   where b.id = v_item.batch_id
     and b.locked_by = p_worker_id;

  return v_item;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_mdac_fill_preview(p_item_id uuid, p_worker_id text, p_screenshot_path text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_has_more boolean;
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'preview_only', true,
      'submitted', false,
      'result_confirmed', false,
      'worker_id', p_worker_id
    );
begin
  perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;

  update public.automation_items
     set status = 'NEEDS_REVIEW',
         finished_at = now(),
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = p_error_code,
         error_message = p_error_message,
         result_unknown = false
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
  returning * into v_item;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select * into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent MDAC batch not found';
  end if;

  insert into public.mdac_registrations (
    customer_id,
    batch_item_id,
    entry_date,
    exit_date,
    registration_no,
    registration_status,
    raw_summary,
    screenshot_path,
    submitted_at,
    result_confirmed_at
  ) values (
    v_item.customer_id,
    v_item.id,
    v_batch.entry_date,
    v_batch.exit_date,
    null,
    'NEEDS_REVIEW',
    v_summary,
    p_screenshot_path,
    null,
    null
  )
  on conflict (batch_item_id) do update set
    registration_status = 'NEEDS_REVIEW',
    raw_summary = excluded.raw_summary,
    screenshot_path = excluded.screenshot_path,
    submitted_at = null,
    result_confirmed_at = null,
    updated_at = now();

  select exists (
    select 1 from public.automation_items i
     where i.batch_id = v_item.batch_id
       and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
  ) into v_has_more;

  update public.automation_batches b
     set locked_by = case when v_has_more then b.locked_by else null end,
         locked_at = case when v_has_more then b.locked_at else null end,
         lease_expires_at = case when v_has_more then now() + interval '15 minutes' else null end,
         success_count = (
           select count(*) from public.automation_items i
            where i.batch_id = b.id and i.status in ('SUCCEEDED', 'NEEDS_REVIEW')
         ),
         failed_count = (
           select count(*) from public.automation_items i
            where i.batch_id = b.id and i.status = 'FAILED'
         ),
         status = case
           when not v_has_more and exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'NEEDS_REVIEW'
           ) then 'NEEDS_REVIEW'::public.automation_status
           when not v_has_more then 'SUCCEEDED'::public.automation_status
           else b.status
         end,
         updated_at = now()
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
    'MDAC_FILL_PREVIEW',
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'submitted', false,
      'result_confirmed', false,
      'screenshot_path', p_screenshot_path,
      'error_code', p_error_code
    )
  );

  return v_item;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_registration_check_worker(p_item_id uuid, p_worker_id text, p_outcome text, p_evidence_path text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_now timestamptz := now();
  v_outcome text := upper(trim(coalesce(p_outcome, 'NEEDS_REVIEW')));
  v_item_status public.automation_item_status;
  v_check_status public.check_status;
  v_business public.business_status;
  v_normalized text;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_summary jsonb;
begin
  perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_outcome not in ('FOUND', 'NO_RECORD', 'PIN_INVALID', 'PAGE_ERROR', 'NEEDS_REVIEW') then
    raise exception 'invalid check outcome: %', v_outcome;
  end if;

  select *
    into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
   for update;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select *
    into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent batch not found';
  end if;

  if v_outcome = 'FOUND' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'FOUND';
    v_business := 'REGISTRATION_CHECKED';
    v_error_code := null;
    v_error_message := null;
  elsif v_outcome = 'NO_RECORD' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'NO_RECORD';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'NO_RECORD');
    v_error_message := coalesce(p_error_message, '官方页面显示无记录');
  elsif v_outcome = 'PIN_INVALID' then
    v_item_status := 'FAILED';
    v_check_status := 'FAILED';
    v_normalized := 'PIN_INVALID';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'PIN_INVALID');
    v_error_message := coalesce(p_error_message, '官方页面提示 PIN 错误');
  else
    v_item_status := 'NEEDS_REVIEW';
    v_check_status := 'NEEDS_REVIEW';
    v_normalized := coalesce(p_error_code, 'PAGE_ERROR');
    v_business := null;
    v_error_code := coalesce(p_error_code, 'NEEDS_HUMAN_INTERVENTION');
    v_error_message := coalesce(p_error_message, 'Check Registration 需要人工审核');
  end if;

  v_summary := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'auto_worker', true,
      'submitted', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
      'result_confirmed', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
      'completed_at', v_now
    );

  update public.automation_items
     set status = v_item_status,
         finished_at = case when v_item_status = 'NEEDS_REVIEW' then null else v_now end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = (v_item_status = 'NEEDS_REVIEW')
   where id = v_item.id
  returning * into v_item;

  insert into public.registration_checks (
    customer_id,
    case_id,
    batch_item_id,
    checked_at,
    result_status,
    raw_summary,
    normalized_status,
    error_message,
    screenshot_path,
    challenge_type,
    submitted,
    result_confirmed
  ) values (
    v_item.customer_id,
    v_item.case_id,
    v_item.id,
    v_now,
    v_check_status,
    v_summary,
    v_normalized,
    v_error_message,
    nullif(trim(p_evidence_path), ''),
    'CAPTCHA_SLIDER',
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID')
  )
  on conflict (batch_item_id) do update set
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = coalesce(excluded.screenshot_path, registration_checks.screenshot_path),
    challenge_type = excluded.challenge_type,
    submitted = excluded.submitted,
    result_confirmed = excluded.result_confirmed,
    updated_at = v_now;

  if v_business is not null then
    update public.customers
       set business_status = v_business,
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  end if;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'REGISTRATION_CHECK_AUTO_WORKER',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_batch.id,
      'customer_id', v_item.customer_id,
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'status', v_item_status
    )
  );

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where b.id = v_item.batch_id
     and not exists (
       select 1
         from public.automation_items i
        where i.batch_id = b.id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
     );

  return v_item;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_registration_check_item(p_item_id uuid, p_worker_id text, p_check_status check_status, p_normalized_status text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_screenshot_path text DEFAULT NULL::text, p_challenge_type text DEFAULT NULL::text, p_result_confirmed boolean DEFAULT false, p_result_unknown boolean DEFAULT false, p_retryable boolean DEFAULT false, p_max_attempts integer DEFAULT 5, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.automation_items;
  v_terminal_status public.automation_item_status;
  v_next_business_status public.business_status;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_confirmed boolean := coalesce(p_result_confirmed, false);
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'execution_mode', 'REGISTRATION_CHECK',
      'submitted', false,
      'result_confirmed', v_confirmed,
      'captcha_bypass', false,
      'challenge_type', p_challenge_type
    );
begin
  perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null or p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'item_id and worker_id are required';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;
  select * into v_item
    from public.automation_items i
   where i.id = p_item_id
     and i.locked_by = p_worker_id
     and i.status in ('CLAIMED', 'RUNNING');
  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  if p_check_status = 'PARSED' and v_confirmed then
    v_terminal_status := 'SUCCEEDED';
    v_next_business_status := 'REGISTRATION_CHECKED';
    v_error_code := p_error_code;
    v_error_message := p_error_message;
  elsif p_check_status = 'PARSED' and not v_confirmed then
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'RESULT_NOT_CONFIRMED');
    v_error_message := coalesce(p_error_message, 'Parsed result requires authorized confirmation');
  elsif p_check_status = 'FAILED' and p_retryable and v_item.attempt_count < p_max_attempts then
    v_terminal_status := 'QUEUED';
    v_next_business_status := null;
    v_error_code := coalesce(p_error_code, 'REGISTRATION_CHECK_RETRY');
    v_error_message := coalesce(p_error_message, 'Registration Check failed transiently; waiting for retry');
  elsif p_check_status = 'FAILED' then
    v_terminal_status := 'FAILED';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'REGISTRATION_CHECK_FAILED');
    v_error_message := coalesce(p_error_message, 'Registration Check failed');
  else
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, case
      when p_challenge_type is not null then 'MANUAL_CHALLENGE_REQUIRED'
      when p_check_status = 'UNPARSED' then 'REGISTRATION_RESULT_UNPARSED'
      else 'REGISTRATION_CHECK_REVIEW'
    end);
    v_error_message := coalesce(p_error_message, 'Registration Check requires manual review');
  end if;

  insert into public.registration_checks (
    customer_id,
    case_id,
    batch_item_id,
    checked_at,
    result_status,
    raw_summary,
    normalized_status,
    error_message,
    screenshot_path,
    challenge_type,
    submitted,
    result_confirmed
  ) values (
    v_item.customer_id,
    v_item.case_id,
    v_item.id,
    case when v_terminal_status = 'QUEUED' then null else now() end,
    case when v_terminal_status = 'FAILED' then 'FAILED'::public.check_status
         when p_check_status = 'PARSED' and v_confirmed then 'PARSED'::public.check_status
         else 'NEEDS_REVIEW'::public.check_status end,
    v_summary,
    nullif(trim(p_normalized_status), ''),
    v_error_message,
    nullif(trim(p_screenshot_path), ''),
    nullif(trim(p_challenge_type), ''),
    false,
    v_confirmed
  )
  on conflict (batch_item_id) do update set
    case_id = excluded.case_id,
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = excluded.screenshot_path,
    challenge_type = excluded.challenge_type,
    submitted = false,
    result_confirmed = v_confirmed,
    updated_at = now();

  update public.automation_items
     set status = v_terminal_status,
         finished_at = case when v_terminal_status = 'QUEUED' then null else now() end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = coalesce(p_result_unknown, false)
   where id = v_item.id;

  if v_next_business_status is not null then
    update public.customers
       set business_status = v_next_business_status,
           updated_at = now()
     where id = v_item.customer_id;
  end if;

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         status = case
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
           ) then 'QUEUED'::public.automation_status
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'NEEDS_REVIEW'
           ) then 'NEEDS_REVIEW'::public.automation_status
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'FAILED'
           ) then 'FAILED'::public.automation_status
           else 'SUCCEEDED'::public.automation_status
         end,
         note = coalesce(b.note, '') || case
           when v_terminal_status = 'QUEUED' then ' | Check Registration 暂时失败，等待重试'
           when p_challenge_type is not null then ' | 检测到官方 CAPTCHA/滑块，等待人工处理；未提交'
           when v_terminal_status = 'FAILED' then ' | Check Registration 失败，需人工处理'
           when v_terminal_status = 'SUCCEEDED' then ' | Check Registration 查询完成'
           else ' | Check Registration 结果待确认'
         end
   where b.id = v_item.batch_id and b.locked_by = p_worker_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    case when v_confirmed then 'REGISTRATION_CHECK_COMPLETED' else 'REGISTRATION_CHECK_REVIEW' end,
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'check_status', p_check_status,
      'result_unknown', coalesce(p_result_unknown, false),
      'submitted', false,
      'result_confirmed', v_confirmed,
      'error_code', v_error_code
    )
  );

  select * into v_item from public.automation_items where id = v_item.id;
  return v_item;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_visit_pass_check_worker(p_item_id uuid, p_worker_id text, p_outcome text, p_evidence_path text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  v_item public.automation_items;
  v_batch public.automation_batches;
  v_now timestamptz := now();
  v_outcome text := upper(trim(coalesce(p_outcome, 'NEEDS_REVIEW')));
  v_item_status public.automation_item_status;
  v_check_status public.check_status;
  v_business public.business_status;
  v_normalized text;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_summary jsonb;
begin
  perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null then
    raise exception 'item_id is required';
  end if;
  if p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'worker_id is required';
  end if;
  if v_outcome not in ('FOUND', 'NO_RECORD', 'PIN_INVALID', 'PAGE_ERROR', 'NEEDS_REVIEW') then
    raise exception 'invalid check outcome: %', v_outcome;
  end if;

  select *
    into v_item
    from public.automation_items
   where id = p_item_id
     and locked_by = p_worker_id
     and status in ('CLAIMED', 'RUNNING')
   for update;

  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  select *
    into v_batch
    from public.automation_batches
   where id = v_item.batch_id;

  if not found then
    raise exception 'parent batch not found';
  end if;

  if v_outcome = 'FOUND' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'FOUND';
    v_business := 'VISIT_PASS_CHECKED';
    v_error_code := null;
    v_error_message := null;
  elsif v_outcome = 'NO_RECORD' then
    v_item_status := 'SUCCEEDED';
    v_check_status := 'PARSED';
    v_normalized := 'NO_RECORD';
    v_business := 'VISIT_PASS_NOT_FOUND';
    v_error_code := coalesce(p_error_code, 'NO_RECORD');
    v_error_message := coalesce(p_error_message, '官方页面显示未出（未匹配记录）');
  elsif v_outcome = 'PIN_INVALID' then
    v_item_status := 'FAILED';
    v_check_status := 'FAILED';
    v_normalized := 'PIN_INVALID';
    v_business := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'PIN_INVALID');
    v_error_message := coalesce(p_error_message, '官方页面提示 PIN 错误');
  else
    v_item_status := 'NEEDS_REVIEW';
    v_check_status := 'NEEDS_REVIEW';
    v_normalized := coalesce(p_error_code, 'PAGE_ERROR');
    v_business := null;
    v_error_code := coalesce(p_error_code, 'NEEDS_HUMAN_INTERVENTION');
    v_error_message := coalesce(p_error_message, 'Check Visit Pass 需要人工审核');
  end if;

  v_summary := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'auto_worker', true,
      'submitted', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
      'result_confirmed', v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
      'completed_at', v_now
    );

  update public.automation_items
     set status = v_item_status,
         finished_at = case when v_item_status = 'NEEDS_REVIEW' then null else v_now end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = (v_item_status = 'NEEDS_REVIEW')
   where id = v_item.id
  returning * into v_item;

  insert into public.visit_pass_checks (
    customer_id,
    case_id,
    batch_item_id,
    checked_at,
    result_status,
    raw_summary,
    normalized_status,
    error_message,
    screenshot_path,
    challenge_type,
    submitted,
    result_confirmed
  ) values (
    v_item.customer_id,
    v_item.case_id,
    v_item.id,
    v_now,
    v_check_status,
    v_summary,
    v_normalized,
    v_error_message,
    nullif(trim(p_evidence_path), ''),
    'CAPTCHA_SLIDER',
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID'),
    v_outcome in ('FOUND', 'NO_RECORD', 'PIN_INVALID')
  )
  on conflict (batch_item_id) do update set
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = coalesce(excluded.screenshot_path, visit_pass_checks.screenshot_path),
    challenge_type = excluded.challenge_type,
    submitted = excluded.submitted,
    result_confirmed = excluded.result_confirmed,
    updated_at = v_now;

  if v_business is not null then
    update public.customers
       set business_status = v_business,
           updated_at = v_now
     where id = v_item.customer_id
       and deleted_at is null;
  end if;

  insert into public.audit_logs (actor_id, action, entity_type, entity_id, metadata)
  values (
    null,
    'VISIT_PASS_CHECK_AUTO_WORKER',
    'automation_items',
    v_item.id,
    jsonb_build_object(
      'batch_id', v_batch.id,
      'customer_id', v_item.customer_id,
      'worker_id', p_worker_id,
      'outcome', v_outcome,
      'status', v_item_status
    )
  );

  -- Unlock batch if all items are done
  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null
   where b.id = v_item.batch_id
     and not exists (
       select 1
         from public.automation_items i
        where i.batch_id = b.id
          and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
     );

  return v_item;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_visit_pass_check_item(p_item_id uuid, p_worker_id text, p_check_status check_status, p_normalized_status text DEFAULT NULL::text, p_raw_summary jsonb DEFAULT '{}'::jsonb, p_screenshot_path text DEFAULT NULL::text, p_challenge_type text DEFAULT NULL::text, p_result_confirmed boolean DEFAULT false, p_result_unknown boolean DEFAULT false, p_retryable boolean DEFAULT false, p_max_attempts integer DEFAULT 5, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text)
 RETURNS automation_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.automation_items;
  v_terminal_status public.automation_item_status;
  v_next_business_status public.business_status;
  v_error_code text := p_error_code;
  v_error_message text := p_error_message;
  v_confirmed boolean := coalesce(p_result_confirmed, false);
  v_summary jsonb := coalesce(p_raw_summary, '{}'::jsonb)
    || jsonb_build_object(
      'worker_id', p_worker_id,
      'execution_mode', 'VISIT_PASS_CHECK',
      'submitted', false,
      'result_confirmed', false,
      'captcha_bypass', false,
      'challenge_type', p_challenge_type
    );
begin
  perform private.mdac_require_fence(p_worker_id,null,p_item_id);
  if p_item_id is null or p_worker_id is null or length(trim(p_worker_id)) = 0 then
    raise exception 'item_id and worker_id are required';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max_attempts must be between 1 and 20';
  end if;
  if v_confirmed then
    raise exception 'current Visit Pass Check worker cannot confirm results';
  end if;

  select * into v_item
    from public.automation_items i
   where i.id = p_item_id
     and i.locked_by = p_worker_id
     and i.status in ('CLAIMED', 'RUNNING');
  if not found then
    raise exception 'item is not owned by worker or is no longer active';
  end if;

  if p_check_status = 'PARSED' and not v_confirmed then
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'RESULT_NOT_CONFIRMED');
    v_error_message := coalesce(p_error_message, 'Parsed result requires authorized confirmation');
  elsif p_check_status = 'FAILED' and p_retryable and v_item.attempt_count < p_max_attempts then
    v_terminal_status := 'QUEUED';
    v_next_business_status := null;
    v_error_code := coalesce(p_error_code, 'VISIT_PASS_CHECK_RETRY');
    v_error_message := coalesce(p_error_message, 'Visit Pass Check failed transiently; waiting for retry');
  elsif p_check_status = 'FAILED' then
    v_terminal_status := 'FAILED';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, 'VISIT_PASS_CHECK_FAILED');
    v_error_message := coalesce(p_error_message, 'Visit Pass Check failed');
  else
    v_terminal_status := 'NEEDS_REVIEW';
    v_next_business_status := 'ACTION_REQUIRED';
    v_error_code := coalesce(p_error_code, case
      when p_challenge_type is not null then 'MANUAL_CHALLENGE_REQUIRED'
      when p_check_status = 'UNPARSED' then 'VISIT_PASS_RESULT_UNPARSED'
      else 'VISIT_PASS_CHECK_REVIEW'
    end);
    v_error_message := coalesce(p_error_message, 'Visit Pass Check requires manual review');
  end if;

  insert into public.visit_pass_checks (
    customer_id,
    batch_item_id,
    checked_at,
    result_status,
    raw_summary,
    normalized_status,
    error_message,
    screenshot_path,
    challenge_type,
    submitted,
    result_confirmed
  ) values (
    v_item.customer_id,
    v_item.id,
    case when v_terminal_status = 'QUEUED' then null else now() end,
    case when v_terminal_status = 'FAILED' then 'FAILED'::public.check_status
         when p_check_status = 'PARSED' and v_confirmed then 'PARSED'::public.check_status
         else 'NEEDS_REVIEW'::public.check_status end,
    v_summary,
    nullif(trim(p_normalized_status), ''),
    v_error_message,
    nullif(trim(p_screenshot_path), ''),
    nullif(trim(p_challenge_type), ''),
    false,
    false
  )
  on conflict (batch_item_id) do update set
    checked_at = excluded.checked_at,
    result_status = excluded.result_status,
    raw_summary = excluded.raw_summary,
    normalized_status = excluded.normalized_status,
    error_message = excluded.error_message,
    screenshot_path = excluded.screenshot_path,
    challenge_type = excluded.challenge_type,
    submitted = false,
    result_confirmed = false,
    updated_at = now();

  update public.automation_items
     set status = v_terminal_status,
         finished_at = case when v_terminal_status = 'QUEUED' then null else now() end,
         locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         error_code = v_error_code,
         error_message = v_error_message,
         result_unknown = coalesce(p_result_unknown, false)
   where id = v_item.id;

  if v_next_business_status is not null then
    update public.customers
       set business_status = v_next_business_status,
           updated_at = now()
     where id = v_item.customer_id;
  end if;

  update public.automation_batches b
     set locked_by = null,
         locked_at = null,
         lease_expires_at = null,
         status = case
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status in ('QUEUED', 'CLAIMED', 'RUNNING')
           ) then 'QUEUED'::public.automation_status
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'NEEDS_REVIEW'
           ) then 'NEEDS_REVIEW'::public.automation_status
           when exists (
             select 1 from public.automation_items i
              where i.batch_id = b.id
                and i.status = 'FAILED'
           ) then 'FAILED'::public.automation_status
           else b.status
         end,
         note = coalesce(b.note, '') || case
           when v_terminal_status = 'QUEUED' then ' | Check Visit Pass 暂时失败，等待重试'
           when p_challenge_type is not null then ' | 检测到官方 CAPTCHA/滑块，等待人工处理；未提交'
           when v_terminal_status = 'FAILED' then ' | Check Visit Pass 失败，需人工处理'
           else ' | Check Visit Pass 结果待确认；未提交'
         end
   where b.id = v_item.batch_id and b.locked_by = p_worker_id;

  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'VISIT_PASS_CHECK_REVIEW',
    'automation_items',
    v_item.id,
    v_summary || jsonb_build_object(
      'batch_id', v_item.batch_id,
      'check_status', p_check_status,
      'result_unknown', coalesce(p_result_unknown, false),
      'submitted', false,
      'result_confirmed', false,
      'error_code', v_error_code
    )
  );

  select * into v_item from public.automation_items where id = v_item.id;
  return v_item;
end;
$function$
;

create or replace function public.mdac_begin_external_v2(p_worker_id text,p_item_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 -- A single global permit preserves a conservative external concurrency limit.
 perform pg_advisory_xact_lock(548531821);
 perform private.mdac_require_fence(p_worker_id,null,p_item_id);
 if exists(select 1 from public.automation_items where id=p_item_id and external_started_at is not null) then return true; end if;
 if exists(select 1 from public.automation_items where id<>p_item_id and external_started_at is not null
   and status::text in ('RUNNING','CLAIMED') and lease_expires_at>clock_timestamp()) then return false; end if;
 update public.automation_items set external_started_at=clock_timestamp() where id=p_item_id;
 return true;
end $$;
create or replace function public.mdac_before_submit_v2(p_worker_id text,p_item_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.mdac_require_fence(p_worker_id,null,p_item_id);
 if not exists(select 1 from public.automation_items where id=p_item_id and external_started_at is not null
   and submission_started_at is null) then raise exception 'Submission cannot be repeated'; end if;
 update public.automation_items set submission_started_at=clock_timestamp() where id=p_item_id;
end $$;
create or replace function public.mdac_release_batch_v2(p_worker_id text,p_batch_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.mdac_require_fence(p_worker_id,p_batch_id);
 if exists(select 1 from public.automation_items where batch_id=p_batch_id and status::text in ('CLAIMED','RUNNING')) then
   raise exception 'Cannot release an in-flight item'; end if;
 update public.automation_batches set locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=p_batch_id;
 perform private.sync_batch_status_and_counts(p_batch_id);
end $$;
create or replace function public.mdac_protocol_info_v2() returns jsonb
language sql security invoker set search_path='' as $$select jsonb_build_object('protocol',2,'max_external_concurrency',1)$$;
revoke all on function public.mdac_begin_external_v2(text,uuid),public.mdac_before_submit_v2(text,uuid),
 public.mdac_release_batch_v2(text,uuid),public.mdac_protocol_info_v2() from public,anon,authenticated;
grant execute on function public.mdac_begin_external_v2(text,uuid),public.mdac_before_submit_v2(text,uuid),
 public.mdac_release_batch_v2(text,uuid),public.mdac_protocol_info_v2() to service_role;

create or replace function public.requeue_automation_batch(p_batch_id uuid)
returns public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' and not private.is_active_user() then raise exception 'Active user required' using errcode='42501'; end if;
 select * into b from public.automation_batches where id=p_batch_id for update;
 if not found then raise exception 'Batch not found'; end if;
 if coalesce(auth.jwt()->>'role','')<>'service_role' and b.created_by is distinct from auth.uid() then
   raise exception 'Only the batch owner may retry it' using errcode='42501'; end if;
 perform 1 from public.automation_items where batch_id=p_batch_id order by id for update;
 if b.lease_expires_at>clock_timestamp() or exists(select 1 from public.automation_items where batch_id=p_batch_id
   and (status::text in ('CLAIMED','RUNNING','QUEUED') or result_unknown
        or (submission_started_at is not null and status::text<>'SUCCEEDED'))) then
   raise exception 'G1/G2: active or uncertain work cannot be automatically requeued'; end if;
 update public.automation_items set status='QUEUED',locked_by=null,locked_at=null,lease_expires_at=null,
   claim_token=null,external_started_at=null,started_at=null,finished_at=null,error_code=null,error_message=null
 where batch_id=p_batch_id and status::text='FAILED' and not result_unknown and submission_started_at is null and attempt_count<5;
 if not found then raise exception 'No safely retryable failed items'; end if;
 update public.automation_batches set locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=p_batch_id;
 perform private.sync_batch_status_and_counts(p_batch_id);
 select * into b from public.automation_batches where id=p_batch_id;
 return b;
end $$;
notify pgrst,'reload schema';
