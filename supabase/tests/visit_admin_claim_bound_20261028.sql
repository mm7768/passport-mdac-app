begin;
create schema visit_retarget_acceptance_20261028;
create table visit_retarget_acceptance_20261028.automation_batches(id uuid primary key,task_type text,created_by uuid,status text,lease_expires_at timestamptz,attempt_count int,visit_pass_settings_snapshot jsonb,entry_date date,locked_by text,locked_at timestamptz,claim_token uuid);
create table visit_retarget_acceptance_20261028.automation_items(id uuid primary key,batch_id uuid,customer_id uuid,case_id uuid,status text,attempt_count int,locked_by text,locked_at timestamptz,lease_expires_at timestamptz,claim_token uuid,external_started_at timestamptz,started_at timestamptz,finished_at timestamptz,error_code text,error_message text,result_unknown boolean,submission_started_at timestamptz);
create table visit_retarget_acceptance_20261028.customers(id uuid primary key,deleted_at timestamptz,website_archived_at timestamptz);
create table visit_retarget_acceptance_20261028.customer_cases(id uuid primary key,website_archived_at timestamptz);
create table visit_retarget_acceptance_20261028.visit_pass_checks(id uuid primary key,batch_item_id uuid);
create table visit_retarget_acceptance_20261028.audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,metadata jsonb);
create table visit_retarget_acceptance_20261028.automation_manual_retry_requests(actor_id uuid,request_id uuid,batch_id uuid,snapshot_token text,include_uncertain boolean,response jsonb,post_snapshot_token text,primary key(actor_id,request_id));
create table visit_retarget_acceptance_20261028.automation_manual_retry_history(actor_id uuid,request_id uuid,batch_id uuid,item_id uuid,customer_id uuid,case_id uuid,attempt_count int,risk_class text,uncertain_reexecution_confirmed boolean,before_item jsonb,before_batch_state jsonb,before_results jsonb,primary key(actor_id,request_id,item_id));
create function visit_retarget_acceptance_20261028.automation_manual_retry_assert_actor(actor uuid) returns void language plpgsql as $stub$ begin if actor is null then raise exception 'actor required' using errcode='42501'; end if; end $stub$;
create function visit_retarget_acceptance_20261028.automation_manual_retry_state(batch uuid) returns jsonb language sql as $stub$ select jsonb_build_object('snapshot_token',md5(batch::text)) $stub$;
create function visit_retarget_acceptance_20261028.sync_batch_status_and_counts(batch uuid) returns void language sql as $stub$ update visit_retarget_acceptance_20261028.automation_batches set status='QUEUED' where id=batch $stub$;
create table visit_retarget_acceptance_20261028.checks(name text,passed boolean);
-- Administrative RPC: no application role receives execution permission.
create function visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(p_batch_id uuid,p_request_id uuid,p_email text,p_entry_date date,p_batch_attempt_limit integer)
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare b visit_retarget_acceptance_20261028.automation_batches; i visit_retarget_acceptance_20261028.automation_items; actor uuid:=auth.uid();
 req visit_retarget_acceptance_20261028.automation_manual_retry_requests; state jsonb; result jsonb; n integer:=0;
 target_email text:=lower(btrim(p_email));
begin
 if current_user not in ('postgres','supabase_admin') then raise exception 'Maintenance role required' using errcode='42501'; end if;
 perform visit_retarget_acceptance_20261028.automation_manual_retry_assert_actor(actor);
 if p_batch_attempt_limit is null or p_batch_attempt_limit not between 5 and 20 then raise exception 'Invalid maintenance claim bound'; end if;
 if p_request_id is null or p_entry_date is null or target_email is null or length(target_email)>254
 or target_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+[.][a-z]{2,}$' then raise exception 'Invalid request, email or entry date'; end if;
 select * into b from visit_retarget_acceptance_20261028.automation_batches where id=p_batch_id for update;
 if not found or b.task_type::text<>'VISIT_PASS_CHECK' or b.created_by is distinct from actor then raise exception 'Owned Visit Pass batch required' using errcode='42501'; end if;
 select * into req from visit_retarget_acceptance_20261028.automation_manual_retry_requests where actor_id=actor and request_id=p_request_id for update;
 if found then
  if req.batch_id<>p_batch_id or req.response->>'email' is distinct from target_email or req.response->>'entry_date' is distinct from p_entry_date::text or req.response->>'maintenance_batch_attempt_limit' is distinct from p_batch_attempt_limit::text then raise exception 'Request ID reused with different arguments'; end if;
  return req.response||jsonb_build_object('replayed',true);
 end if;
 perform 1 from visit_retarget_acceptance_20261028.automation_items where batch_id=p_batch_id order by id for update;
 if b.lease_expires_at>clock_timestamp() or b.status::text in ('RUNNING','CLAIMED')
 or exists(select 1 from visit_retarget_acceptance_20261028.automation_items where batch_id=p_batch_id and (status::text in ('RUNNING','CLAIMED') or lease_expires_at>clock_timestamp())) then raise exception 'Drain the Worker before changing query settings'; end if;
 if b.attempt_count>=p_batch_attempt_limit or exists(select 1 from visit_retarget_acceptance_20261028.automation_items where batch_id=p_batch_id and status::text<>'SUCCEEDED' and attempt_count>=5) then raise exception 'Attempt limit reached'; end if;
 if exists(select 1 from visit_retarget_acceptance_20261028.automation_items x join visit_retarget_acceptance_20261028.customers c on c.id=x.customer_id left join visit_retarget_acceptance_20261028.customer_cases cc on cc.id=x.case_id where x.batch_id=p_batch_id and (c.deleted_at is not null or c.website_archived_at is not null or cc.website_archived_at is not null)) then raise exception 'Archived or deleted context'; end if;
 if exists(select 1 from visit_retarget_acceptance_20261028.automation_items x join visit_retarget_acceptance_20261028.automation_items other_i on other_i.customer_id=x.customer_id and other_i.batch_id<>p_batch_id where x.batch_id=p_batch_id and other_i.status::text in ('QUEUED','CLAIMED','RUNNING','NEEDS_REVIEW')) then raise exception 'Another task is active for a selected customer'; end if;
 if not exists(select 1 from visit_retarget_acceptance_20261028.automation_items where batch_id=p_batch_id and status::text in ('QUEUED','FAILED','NEEDS_REVIEW')) then raise exception 'No unfinished query items'; end if;
 state:=visit_retarget_acceptance_20261028.automation_manual_retry_state(p_batch_id);
 insert into visit_retarget_acceptance_20261028.automation_manual_retry_requests(actor_id,request_id,batch_id,snapshot_token,include_uncertain)
 values(actor,p_request_id,p_batch_id,state->>'snapshot_token',false);
 for i in select * from visit_retarget_acceptance_20261028.automation_items where batch_id=p_batch_id and status::text in ('QUEUED','FAILED','NEEDS_REVIEW') order by id loop
  insert into visit_retarget_acceptance_20261028.automation_manual_retry_history(actor_id,request_id,batch_id,item_id,customer_id,case_id,attempt_count,risk_class,uncertain_reexecution_confirmed,before_item,before_batch_state,before_results)
  values(actor,p_request_id,p_batch_id,i.id,i.customer_id,i.case_id,i.attempt_count,'SAFE',false,to_jsonb(i),to_jsonb(b),jsonb_build_object('visit_pass_check',coalesce((select jsonb_agg(to_jsonb(v) order by v.id) from visit_retarget_acceptance_20261028.visit_pass_checks v where v.batch_item_id=i.id),'[]'::jsonb)));
  update visit_retarget_acceptance_20261028.automation_items set status='QUEUED',locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null,external_started_at=null,started_at=null,finished_at=null,error_code=null,error_message=null,result_unknown=false,submission_started_at=null where id=i.id;
  n:=n+1;
 end loop;
 update visit_retarget_acceptance_20261028.automation_batches set visit_pass_settings_snapshot=jsonb_set(visit_pass_settings_snapshot,'{email}',to_jsonb(target_email)),entry_date=p_entry_date,locked_by=null,locked_at=null,lease_expires_at=null,claim_token=null where id=p_batch_id;
 perform visit_retarget_acceptance_20261028.sync_batch_status_and_counts(p_batch_id);
 result:=jsonb_build_object('status','QUEUED','replayed',false,'task_type','VISIT_PASS_CHECK','requeued_count',n,'email',target_email,'entry_date',p_entry_date,'request_id',p_request_id,'maintenance_batch_attempt_limit',p_batch_attempt_limit);
 update visit_retarget_acceptance_20261028.automation_manual_retry_requests set response=result,post_snapshot_token=visit_retarget_acceptance_20261028.automation_manual_retry_state(p_batch_id)->>'snapshot_token' where actor_id=actor and request_id=p_request_id;
 insert into visit_retarget_acceptance_20261028.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'VISIT_PASS_BATCH_RETARGET','automation_batches',p_batch_id,jsonb_build_object('request_id',p_request_id,'requeued_count',n,'entry_date',p_entry_date,'batch_settings_only',true,'history_preserved',true));
 return result;
end $fn$;
revoke all on function visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(uuid,uuid,text,date,integer) from public,anon,authenticated,service_role;

do $tests$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); req uuid:=gen_random_uuid(); answer jsonb; failed boolean;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 insert into visit_retarget_acceptance_20261028.customers values(c,null,null); insert into visit_retarget_acceptance_20261028.customer_cases values(o,null);
 insert into visit_retarget_acceptance_20261028.automation_batches(id,task_type,created_by,status,attempt_count,visit_pass_settings_snapshot) values(b,'VISIT_PASS_CHECK',a,'QUEUED',2,'{"email":"old@example.test","mobile":"10000","region_code":"86"}');
 insert into visit_retarget_acceptance_20261028.automation_items(id,batch_id,customer_id,case_id,status,attempt_count,result_unknown) values(gen_random_uuid(),b,c,o,'QUEUED',0,false),(gen_random_uuid(),b,c,o,'NEEDS_REVIEW',2,true),(gen_random_uuid(),b,c,o,'SUCCEEDED',1,false);
 update visit_retarget_acceptance_20261028.automation_batches set lease_expires_at=now()+interval '1 minute' where id=b;
 failed:=false;
 begin perform visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,req,'new@example.test',date '2026-10-27',6); exception when raise_exception then failed:=sqlerrm='Drain the Worker before changing query settings'; end;
 insert into visit_retarget_acceptance_20261028.checks values('active lease blocks retarget',failed);
 update visit_retarget_acceptance_20261028.automation_batches set lease_expires_at=null where id=b;
 answer:=visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,req,'new@example.test',date '2026-10-27',6);
 insert into visit_retarget_acceptance_20261028.checks values('unfinished items requeued',(answer->>'requeued_count')::int=2);
 insert into visit_retarget_acceptance_20261028.checks select 'batch email and date changed only',visit_pass_settings_snapshot->>'email'='new@example.test' and visit_pass_settings_snapshot->>'mobile'='10000' and visit_pass_settings_snapshot->>'region_code'='86' and entry_date=date '2026-10-27' from visit_retarget_acceptance_20261028.automation_batches where id=b;
 insert into visit_retarget_acceptance_20261028.checks select 'successful item preserved',count(*)=1 from visit_retarget_acceptance_20261028.automation_items where batch_id=b and status='SUCCEEDED';
 insert into visit_retarget_acceptance_20261028.checks select 'prior states privately recorded',count(*)=2 from visit_retarget_acceptance_20261028.automation_manual_retry_history;
 insert into visit_retarget_acceptance_20261028.checks select 'attempt counts preserved',sum(attempt_count)=3 from visit_retarget_acceptance_20261028.automation_items where batch_id=b;
 answer:=visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,req,'new@example.test',date '2026-10-27',6);
 insert into visit_retarget_acceptance_20261028.checks values('request replay idempotent',(answer->>'replayed')::boolean and (select count(*)=2 from visit_retarget_acceptance_20261028.automation_manual_retry_history));
 failed:=false;
 begin perform visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,req,'other@example.test',date '2026-10-27',6); exception when raise_exception then failed:=sqlerrm='Request ID reused with different arguments'; end;
 insert into visit_retarget_acceptance_20261028.checks values('request argument conflict rejected',failed);
 update visit_retarget_acceptance_20261028.automation_batches set task_type='MDAC_REGISTRATION' where id=b;
 failed:=false;
 begin perform visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,gen_random_uuid(),'new@example.test',date '2026-10-27',6); exception when insufficient_privilege then failed:=true; end;
 insert into visit_retarget_acceptance_20261028.checks values('MDAC registration batch rejected',failed);

 update visit_retarget_acceptance_20261028.automation_batches set task_type='VISIT_PASS_CHECK',attempt_count=5 where id=b;
 failed:=false;
 begin perform visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,gen_random_uuid(),'new@example.test',date '2026-10-27',5); exception when raise_exception then failed:=sqlerrm='Attempt limit reached'; end;
 insert into visit_retarget_acceptance_20261028.checks values('default five-claim bound remains enforced',failed);
 answer:=visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,gen_random_uuid(),'new@example.test',date '2026-10-27',6);
 insert into visit_retarget_acceptance_20261028.checks values('explicit maintenance bound preserves batch counter',(answer->>'requeued_count')::int=2 and (select attempt_count=5 from visit_retarget_acceptance_20261028.automation_batches where id=b));
 update visit_retarget_acceptance_20261028.automation_items set attempt_count=5 where batch_id=b and status<>'SUCCEEDED';
 failed:=false;
 begin perform visit_retarget_acceptance_20261028.retarget_stopped_visit_batch_v1(b,gen_random_uuid(),'new@example.test',date '2026-10-27',6); exception when raise_exception then failed:=sqlerrm='Attempt limit reached'; end;
 insert into visit_retarget_acceptance_20261028.checks values('per-item five-attempt cap remains enforced',failed);

 if exists(select 1 from visit_retarget_acceptance_20261028.checks where passed is not true) then raise exception 'retarget acceptance failed'; end if;
end $tests$;
select jsonb_build_object('passed',count(*) filter(where passed),'failed',count(*) filter(where passed is not true),'checks',jsonb_agg(to_jsonb(c))) as retarget_tests from visit_retarget_acceptance_20261028.checks c;
rollback;
