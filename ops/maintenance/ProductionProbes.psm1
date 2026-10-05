$ErrorActionPreference='Stop'
$script:Workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
function Invoke-MdacReadonlySql([string]$Query){
 . "$PSScriptRoot/Connect-ProductionReadonly.ps1"
 $start=[Diagnostics.ProcessStartInfo]::new("$mdacPgBin/psql.exe");$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false);$start.Environment['PGCLIENTENCODING']='UTF8'
 foreach($arg in @('-X','-qAt','-v','ON_ERROR_STOP=1','-c','SET ROLE postgres;','-f','-')){$start.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::Start($start);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
 $p.StandardInput.Write($Query);$p.StandardInput.Close()
 if(-not $p.WaitForExit(25000)){$p.Kill();throw 'DB_PROBE_TIMEOUT'}
 $value=$out.GetAwaiter().GetResult();[void]$err.GetAwaiter().GetResult();$env:PGPASSWORD=$null
 if($p.ExitCode -ne 0){throw 'DB_READONLY_PROBE_FAILED'}
 return $value.Trim()|ConvertFrom-Json -AsHashtable
}
function Get-MdacDatabaseProbe {
 $sql=@'
select jsonb_build_object('fingerprint',md5(jsonb_build_object(
 'migrations',(select jsonb_agg(version order by version) from supabase_migrations.schema_migrations),
 'functions',(select jsonb_agg(jsonb_build_array(n.nspname,p.oid::regprocedure::text,pg_get_functiondef(p.oid),p.proacl,p.proowner) order by n.nspname,p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private')),
 'columns',(select jsonb_agg(jsonb_build_array(table_schema,table_name,column_name,data_type,is_nullable,column_default) order by table_schema,table_name,ordinal_position) from information_schema.columns where table_schema in ('public','private')),
 'relations',(select jsonb_agg(jsonb_build_array(n.nspname,c.relname,c.relrowsecurity,c.relforcerowsecurity,c.relacl,c.reloptions) order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','private') and c.relkind in ('r','v')),
 'constraints',(select jsonb_agg(jsonb_build_array(n.nspname,c.relname,k.conname,pg_get_constraintdef(k.oid)) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','private')),
 'policies',(select jsonb_agg(jsonb_build_array(schemaname,tablename,policyname,roles,cmd,qual,with_check) order by schemaname,tablename,policyname) from pg_policies where schemaname in ('public','private','storage'))
)::text), 'business_read_ok',exists(select 1 from public.profiles where role='OWNER' and access_mode='FULL' and is_active and deleted_at is null),
'migration_in_progress',exists(select 1 from pg_locks l join pg_class c on c.oid=l.relation join pg_namespace n on n.oid=c.relnamespace where l.pid<>pg_backend_pid() and ((n.nspname in ('public','private') and l.mode='AccessExclusiveLock') or (n.nspname='pg_catalog' and c.relname in ('pg_proc','pg_class','pg_namespace','pg_attribute','pg_constraint') and l.mode in ('RowExclusiveLock','ShareRowExclusiveLock','AccessExclusiveLock')))),
'rows',(select coalesce(jsonb_agg(jsonb_build_object('worker_id',worker_id,'status',status,'last_seen_at',last_seen_at)),'[]'::jsonb) from public.worker_heartbeats));
'@
 $probe=Invoke-MdacReadonlySql $sql
 # Actually execute normal business reads under current active Owner, not just existence.
 $normal=@'
begin read only;
do $$ begin perform set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='OWNER' and access_mode='FULL' and is_active and deleted_at is null limit 1),true);end $$;
set local role authenticated;
select jsonb_build_object('ok', (select count(*) from jsonb_object_keys(public.get_workers_health()))=5,'membership_rows',(select count(*) from public.get_mdac_batch_memberships()),'customer_rows',(select count(*) from public.customers),'order_rows',(select count(*) from public.customer_cases));
rollback;
'@
 $read=Invoke-MdacReadonlySql $normal
 $probe.business_read_ok=$probe.business_read_ok -and $read.ok
 return $probe
}
function Get-MdacWebsiteProbe {
 $cli='C:/Users/wong7768/AppData/Local/npm-cache/_npx/67eb4586ca667318/node_modules/vercel/dist/index.js'
 $result=(& node $cli api '/v9/projects/prj_8776zcuCB1EJLsEMiSojWMjLsyvt?teamId=team_Ds7d1fO3229Rvd1ZHGchx9IQ' --method GET --raw --non-interactive 2>$null|Out-String)
 if($LASTEXITCODE -ne 0){throw 'SITE_VERSION_PROBE_FAILED'}
 $project=$result|ConvertFrom-Json -AsHashtable
 $http=Invoke-WebRequest 'https://mdac-web.vercel.app/login' -TimeoutSec 15
 return @{deployment_id=$project.targets.production.id;ready=$project.targets.production.readyState -eq 'READY';login_ok=$http.StatusCode -eq 200}
}
Export-ModuleMember -Function Get-MdacDatabaseProbe,Get-MdacWebsiteProbe
