-- Isolated DB only, AFTER Website and App rollback. Grants are rolled back.
begin;
do $$ begin
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in ('preview_customer_hard_delete',
    'create_customer_hard_delete_job','mark_customer_hard_delete_storage_cleaned',
    'fail_customer_hard_delete','complete_customer_hard_delete')
    and (has_function_privilege('anon',p.oid,'EXECUTE')
      or has_function_privilege('authenticated',p.oid,'EXECUTE')
      or has_function_privilege('service_role',p.oid,'EXECUTE'))) then
   raise exception 'Rollback left an executable hard-delete RPC';
 end if;
end $$;
grant execute on function public.preview_customer_hard_delete(uuid[]),
 public.create_customer_hard_delete_job(uuid[]),
 public.mark_customer_hard_delete_storage_cleaned(uuid),
 public.fail_customer_hard_delete(uuid,text),
 public.complete_customer_hard_delete(uuid) to anon,authenticated,service_role;
set local role authenticated;
do $test$ declare v_call text; begin
 foreach v_call in array array['select public.preview_customer_hard_delete(array[]::uuid[])',
'select public.create_customer_hard_delete_job(array[]::uuid[])',
'select public.mark_customer_hard_delete_storage_cleaned(gen_random_uuid())',
'select public.fail_customer_hard_delete(gen_random_uuid(),''rollback test'')',
'select public.complete_customer_hard_delete(gen_random_uuid())'] loop
   begin
     execute v_call;
     raise exception 'Rollback RPC accepted: %',v_call using errcode='ZX002';
   exception when insufficient_privilege then
     if sqlerrm is distinct from 'permanent deletion disabled pending reviewed migration' then
       raise exception 'Expected fixed function-body denial, got %',sqlerrm;
     end if;
   end;
 end loop;
end $test$;
reset role;
set local role anon;
do $test$ declare v_call text; begin
 foreach v_call in array array['select public.preview_customer_hard_delete(array[]::uuid[])',
'select public.create_customer_hard_delete_job(array[]::uuid[])',
'select public.mark_customer_hard_delete_storage_cleaned(gen_random_uuid())',
'select public.fail_customer_hard_delete(gen_random_uuid(),''rollback test'')',
'select public.complete_customer_hard_delete(gen_random_uuid())'] loop
   begin
     execute v_call;
     raise exception 'Rollback RPC accepted: %',v_call using errcode='ZX002';
   exception when insufficient_privilege then
     if sqlerrm is distinct from 'permanent deletion disabled pending reviewed migration' then
       raise exception 'Expected fixed function-body denial, got %',sqlerrm;
     end if;
   end;
 end loop;
end $test$;
reset role;
set local role service_role;
do $test$ declare v_call text; begin
 foreach v_call in array array['select public.preview_customer_hard_delete(array[]::uuid[])',
'select public.create_customer_hard_delete_job(array[]::uuid[])',
'select public.mark_customer_hard_delete_storage_cleaned(gen_random_uuid())',
'select public.fail_customer_hard_delete(gen_random_uuid(),''rollback test'')',
'select public.complete_customer_hard_delete(gen_random_uuid())'] loop
   begin
     execute v_call;
     raise exception 'Rollback RPC accepted: %',v_call using errcode='ZX002';
   exception when insufficient_privilege then
     if sqlerrm is distinct from 'permanent deletion disabled pending reviewed migration' then
       raise exception 'Expected fixed function-body denial, got %',sqlerrm;
     end if;
   end;
 end loop;
end $test$;
reset role;
rollback;

