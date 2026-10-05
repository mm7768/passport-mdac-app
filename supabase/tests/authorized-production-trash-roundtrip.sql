-- Explicitly user-authorized existing records ONLY. No production auth/UI claim.
-- psql inputs: customer_id, order_no_1, order_no_2, run_reason.
-- One short repeatable-read transaction: other readers never observe trash state.
begin isolation level repeatable read;
set local lock_timeout='3s';
set local statement_timeout='15s';
select set_config('acceptance.customer',:'customer_id',true) as ignored \gset
select set_config('acceptance.order1',:'order_no_1',true) as ignored \gset
select set_config('acceptance.order2',:'order_no_2',true) as ignored \gset
select set_config('acceptance.reason',:'run_reason',true) as ignored \gset
set local role postgres;
do $$ begin
 if (select count(*) from public.profiles where role='OWNER' and access_mode='FULL'
     and is_active and deleted_at is null and access_expires_at is null)<>1 then
   raise exception 'Exactly one authorized existing Owner context required';
 end if;
 perform set_config('request.jwt.claim.sub',(select id::text from public.profiles
   where role='OWNER' and access_mode='FULL' and is_active and deleted_at is null
     and access_expires_at is null),true);
end $$;
set local role authenticated;
do $test$
declare
 v_customer uuid:=current_setting('acceptance.customer')::uuid;
 v_nos text[]:=array[current_setting('acceptance.order1'),current_setting('acceptance.order2')];
 v_reason text:=current_setting('acceptance.reason');
 v_customer_before jsonb;v_orders_before jsonb;v_orders_after jsonb;
 v_before_summary jsonb;v_summary jsonb;v_dash jsonb;v_result jsonb;v_ids uuid[];
 v_id uuid;v_no text;v_bad_restore_rejected boolean:=false;
 v_price numeric;v_cost numeric;v_profit numeric;v_total integer;v_audit integer;
 v_history_before text;v_history_after text;
begin
 -- Lock in the same order used by production archive RPCs: parent, sorted children.
 select to_jsonb(c)-'updated_at' into v_customer_before from public.customers c
   where c.id=v_customer for update;
 if v_customer_before is null or v_customer_before->>'deleted_at' is not null
   or v_customer_before->>'website_archived_at' is not null then raise exception 'Customer not initially active';end if;
 perform 1 from public.customer_cases where customer_id=v_customer order by id for update;
 if (select count(*) from public.customer_cases where customer_id=v_customer)<>2
   or (select count(*) from public.customer_cases where customer_id=v_customer and order_no=any(v_nos) and website_archived_at is null)<>2
   or v_nos[1]=v_nos[2] then raise exception 'Authorized two-order scope changed';end if;
 select array_agg(id order by id),jsonb_agg(to_jsonb(cc)-'updated_at' order by id),
   coalesce(sum(price),0),coalesce(sum(cost),0),coalesce(sum(price-cost) filter(where price is not null and cost is not null),0)
   into v_ids,v_orders_before,v_price,v_cost,v_profit from public.customer_cases cc where customer_id=v_customer;
 -- The private blocker helper is deliberately NOT granted to authenticated.
 -- Existing public archive RPCs perform the definitive checks below.
 v_before_summary:=public.get_admin_master_summary();v_total:=(v_before_summary->>'total')::integer;
 if (public.get_admin_dashboard()#>>'{summary,total}')::integer<>v_total then raise exception 'Baseline reporting filters differ';end if;
 foreach v_no in array v_nos loop
   if (public.get_admin_master_orders('TOTAL',v_no,1,50)->>'total')::integer<>1 then raise exception 'Initial order query not uniquely visible';end if;
 end loop;
 if (public.get_admin_master_orders('TOTAL',v_customer_before->>'full_name',1,1)->>'total')::integer<>2
   or jsonb_array_length(public.get_admin_master_orders('TOTAL',v_customer_before->>'full_name',1,1)->'items')<>1
   or jsonb_array_length(public.get_admin_master_orders('TOTAL',v_customer_before->>'full_name',2,1)->'items')<>1
   or jsonb_array_length(public.get_admin_master_orders('TOTAL',v_customer_before->>'full_name',3,1)->'items')<>0 then raise exception 'Initial search/pagination failed';end if;
 select md5(jsonb_build_object(
   'passports',(select coalesce(jsonb_agg(to_jsonb(p) order by id),'[]') from public.passports p where customer_id=v_customer),
   'items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.automation_items i where customer_id=v_customer),
   'operational_items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.operational_batch_items i where order_id=any(v_ids)),
   'mdac',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.mdac_registrations r where customer_id=v_customer),
   'registration_checks',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.registration_checks r where customer_id=v_customer),
   'visit_pass_checks',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.visit_pass_checks r where customer_id=v_customer),
   'pin',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.email_pin_records r where customer_id=v_customer)
 )::text) into v_history_before;
 v_result:=public.archive_customer(v_customer,v_reason);
 if v_result->>'status'<>'BLOCKED' or jsonb_array_length(v_result->'blockers')<2 then raise exception 'Unarchived orders failed to block customer archive';end if;
 foreach v_id in array v_ids loop
   v_result:=public.archive_order(v_id,v_reason);
   if v_result->>'status'<>'ARCHIVED' then raise exception 'Order archive blocked; rollback all';end if;
   if public.archive_order(v_id,v_reason)->>'status'<>'ALREADY_ARCHIVED' then raise exception 'Archive idempotency failed';end if;
 end loop;
 v_summary:=public.get_admin_master_summary();v_dash:=public.get_admin_dashboard();
 if (v_summary->>'total')::integer<>v_total-2 or (v_dash#>>'{summary,total}')::integer<>v_total-2
   or (v_summary->>'revenue')::numeric<>(v_before_summary->>'revenue')::numeric-v_price
   or (v_summary->>'cost')::numeric<>(v_before_summary->>'cost')::numeric-v_cost
   or (v_summary->>'profit')::numeric<>(v_before_summary->>'profit')::numeric-v_profit
   or (v_dash#>>'{summary,revenue}')::numeric<>(v_summary->>'revenue')::numeric
   or (v_dash#>>'{summary,cost}')::numeric<>(v_summary->>'cost')::numeric
   or (v_dash#>>'{summary,profit}')::numeric<>(v_summary->>'profit')::numeric then raise exception 'Archive reporting/finance deltas failed';end if;
 foreach v_no in array v_nos loop
   if (public.get_admin_master_orders('TOTAL',v_no,1,50)->>'total')::integer<>0 then raise exception 'Archived order remains in master query';end if;
 end loop;
 if (select count(*) from public.customer_cases where customer_id=v_customer and website_archived_at is null)<>0
   or (select count(*) from public.customer_cases where customer_id=v_customer and website_archived_at is not null)<>2 then raise exception 'Orders/trash query scope failed';end if;
 if public.archive_customer(v_customer,v_reason)->>'status'<>'ARCHIVED' then raise exception 'Customer archive blocked; rollback all';end if;
 if exists(select 1 from public.customer_current_state where id=v_customer)
   or exists(select 1 from public.customers where id=v_customer and website_archived_at is null) then raise exception 'Archived customer visible to App/Website active lists';end if;
 foreach v_id in array v_ids loop
   begin
     perform public.restore_order(v_id,v_reason);
     raise exception 'Wrong restore order unexpectedly allowed' using errcode='ZZ001';
   exception when sqlstate 'P0001' then
     if sqlerrm<>'Restore Customer before restoring Order' then raise;end if;
     v_bad_restore_rejected:=true;
   end;
 end loop;
 if public.restore_customer(v_customer,v_reason)->>'status'<>'RESTORED' then raise exception 'Customer restore failed';end if;
 foreach v_id in array v_ids loop
   if public.restore_order(v_id,v_reason)->>'status'<>'RESTORED' then raise exception 'Order restore failed';end if;
   if public.restore_order(v_id,v_reason)->>'status'<>'ALREADY_ACTIVE' then raise exception 'Restore idempotency failed';end if;
 end loop;
 select jsonb_agg(to_jsonb(cc)-'updated_at' order by id) into v_orders_after from public.customer_cases cc where customer_id=v_customer;
 if v_orders_after is distinct from v_orders_before or
   (select to_jsonb(c)-'updated_at' from public.customers c where id=v_customer) is distinct from v_customer_before then raise exception 'Order/customer business data changed';end if;
 if public.get_admin_master_summary() is distinct from v_before_summary or
   (public.get_admin_dashboard()#>>'{summary,total}')::integer<>v_total or
   not exists(select 1 from public.customer_current_state where id=v_customer) then raise exception 'Restored reporting/customer view differs';end if;
 foreach v_no in array v_nos loop
   if (public.get_admin_master_orders('TOTAL',v_no,1,50)->>'total')::integer<>1 then raise exception 'Restored order query failed';end if;
 end loop;
 select md5(jsonb_build_object(
   'passports',(select coalesce(jsonb_agg(to_jsonb(p) order by id),'[]') from public.passports p where customer_id=v_customer),
   'items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.automation_items i where customer_id=v_customer),
   'operational_items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.operational_batch_items i where order_id=any(v_ids)),
   'mdac',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.mdac_registrations r where customer_id=v_customer),
   'registration_checks',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.registration_checks r where customer_id=v_customer),
   'visit_pass_checks',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.visit_pass_checks r where customer_id=v_customer),
   'pin',(select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from public.email_pin_records r where customer_id=v_customer)
 )::text) into v_history_after;
 if v_history_after is distinct from v_history_before then raise exception 'Passport/history/task/PIN associations changed';end if;
 select count(*) into v_audit from public.audit_logs where metadata->>'reason'=v_reason and actor_id=auth.uid() and action in ('WEBSITE_ARCHIVE','WEBSITE_RESTORE');
 if v_audit<>6 then raise exception 'Expected exactly six archive/restore audit entries';end if;
 perform set_config('acceptance.result',jsonb_build_object('passed',true,'checked_utc',clock_timestamp(),
   'scope','Production SQL functions and reporting in one committed transaction; NOT user Auth/API or browser UI',
   'order_numbers',to_jsonb(v_nos),'customer_blocked_with_active_orders',true,'two_orders_archived',true,
   'customer_archived',true,'restore_orders_before_customer_rejected',v_bad_restore_rejected,
   'customer_then_orders_restored',true,'idempotency_verified',true,'master_search_pagination_verified',true,
   'master_dashboard_finance_deltas_verified',true,'app_customer_view_visibility_verified',true,
   'business_snapshots_finance_ids_unchanged',true,'passport_history_tasks_pin_associations_unchanged',true,
   'audit_entries',v_audit,'final_archived_orders',0,'final_archived_customer',false,
   'intermediate_states_visible_to_other_sessions',false,'permanent_delete_tested',false,
   'app_soft_delete_state_modified',false,'workers_paused',false)::text,true);
end $test$;
select current_setting('acceptance.result');
commit;
