-- Expired work must enter review even when the batch attempt limit has been reached.
create or replace function public.claim_mdac_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='MDAC_REGISTRATION'
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

create or replace function public.claim_registration_check_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='REGISTRATION_CHECK'
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

create or replace function public.claim_visit_pass_check_batch(p_worker_id text,p_lease_seconds integer default 900,p_max_attempts integer default 5)
returns setof public.automation_batches language plpgsql security definer set search_path='' as $$
declare b public.automation_batches;
begin
 perform private.mdac_require_fence(p_worker_id);
 if p_lease_seconds is null or p_max_attempts is null or p_lease_seconds not between 60 and 3600 or p_max_attempts not between 1 and 20 then raise exception 'Invalid lease or attempt bound'; end if;
 select * into b from public.automation_batches q where q.task_type::text='VISIT_PASS_CHECK'
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
notify pgrst,'reload schema';
