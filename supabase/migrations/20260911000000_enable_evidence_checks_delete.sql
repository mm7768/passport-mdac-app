-- Allow authenticated active users to delete customer evidence check records
do $$
begin
  if not exists (
    select 1 from pg_policies 
    where tablename = 'registration_checks' and policyname = 'registration_checks_delete_active'
  ) then
    create policy registration_checks_delete_active on public.registration_checks 
    for delete to authenticated using (private.is_active_user());
  end if;

  if not exists (
    select 1 from pg_policies 
    where tablename = 'visit_pass_checks' and policyname = 'visit_pass_checks_delete_active'
  ) then
    create policy visit_pass_checks_delete_active on public.visit_pass_checks 
    for delete to authenticated using (private.is_active_user());
  end if;
end $$;

-- RPC to atomically delete evidence check and underlying storage object
create or replace function public.delete_customer_human_evidence(
    p_check_id uuid,
    p_type text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_path text;
  v_type text := upper(trim(coalesce(p_type, '')));
begin
  if not private.is_active_user() then
    raise exception 'active user required';
  end if;

  if v_type in ('REGISTRATION_CHECK', 'CHECK_REGISTRATION') then
    select screenshot_path into v_path
      from public.registration_checks
     where id = p_check_id;

    delete from public.registration_checks
     where id = p_check_id;
  elsif v_type in ('VISIT_PASS_CHECK', 'CHECK_VISIT_PASS') then
    select screenshot_path into v_path
      from public.visit_pass_checks
     where id = p_check_id;

    delete from public.visit_pass_checks
     where id = p_check_id;
  else
    raise exception 'unsupported evidence type: %', p_type;
  end if;

  if v_path is not null and length(trim(v_path)) > 0 then
    delete from storage.objects
     where bucket_id = 'passport-documents'
       and name = v_path;
  end if;

  return jsonb_build_object('success', true, 'check_id', p_check_id, 'screenshot_path', v_path);
end;
$$;

revoke execute on function public.delete_customer_human_evidence(uuid, text) from public, anon;
grant execute on function public.delete_customer_human_evidence(uuid, text) to authenticated;
