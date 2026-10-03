-- Some deployed databases have a target-first overload absent from the source
-- history. Preserve its business body, but never leave it as an unguarded route.
-- No-op for clean installations without this overload.
do $migration$
begin
  if to_regprocedure('public.merge_customers_into_batch(uuid,uuid[],text)') is null then
    return;
  end if;
  alter function public.merge_customers_into_batch(uuid,uuid[],text) set schema private;
  alter function private.merge_customers_into_batch(uuid,uuid[],text)
    rename to merge_customers_target_first_before_owner_guard;
  revoke all on function private.merge_customers_target_first_before_owner_guard(uuid,uuid[],text)
    from public,anon,authenticated,service_role;
  execute $ddl$
    create function public.merge_customers_into_batch(
      p_target_batch_id uuid,p_customer_ids uuid[],p_actor text default 'operator'
    ) returns jsonb language plpgsql security definer set search_path = '' as $body$
    declare v_is_owner boolean; v_batch_ids uuid[];
    begin
      if auth.role() = 'service_role' then
        v_is_owner := true;
      else
        select p.role='OWNER' into v_is_owner from public.profiles p
        where p.id=auth.uid() and p.is_active and p.deleted_at is null
          and p.access_mode='FULL'
          and (p.access_expires_at is null or p.access_expires_at>now());
        if not found then
          raise exception 'active full-access user required' using errcode='42501';
        end if;
      end if;
      if p_customer_ids is null or cardinality(p_customer_ids)=0
         or array_position(p_customer_ids,null) is not null or p_target_batch_id is null then
        raise exception 'valid customer ids and target batch required';
      end if;
      perform 1 from public.customers c where c.id=any(p_customer_ids)
        order by c.id for update;
      if exists(select 1 from unnest(p_customer_ids) s(id)
        left join public.customers c on c.id=s.id
        where c.id is null or c.deleted_at is not null
          or (not v_is_owner and c.created_by is distinct from auth.uid())) then
        raise exception 'customer owner or Owner required' using errcode='42501';
      end if;
      select array_agg(distinct b.id) into v_batch_ids from public.automation_batches b
      where b.id=p_target_batch_id or (b.task_type='MDAC_REGISTRATION' and exists(
        select 1 from public.automation_items i
        where i.batch_id=b.id and i.customer_id=any(p_customer_ids)));
      perform 1 from public.automation_batches b where b.id=any(v_batch_ids)
        order by b.id for update;
      if (select task_type from public.automation_batches where id=p_target_batch_id)
          is distinct from 'MDAC_REGISTRATION'::public.automation_task_type then
        raise exception 'target batch must be MDAC_REGISTRATION';
      end if;
      if not v_is_owner and exists(select 1 from public.automation_batches b
        where b.id=any(v_batch_ids) and b.created_by is distinct from auth.uid()) then
        raise exception 'batch owner or Owner required' using errcode='42501';
      end if;
      return private.merge_customers_target_first_before_owner_guard(
        p_target_batch_id,p_customer_ids,p_actor);
    end $body$;
  $ddl$;
  revoke all on function public.merge_customers_into_batch(uuid,uuid[],text)
    from public,anon,authenticated,service_role;
  grant execute on function public.merge_customers_into_batch(uuid,uuid[],text)
    to authenticated,service_role;
end $migration$;
