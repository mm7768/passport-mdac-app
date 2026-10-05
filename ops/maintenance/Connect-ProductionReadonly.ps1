# Official short-lived CLI DB credentials, current Windows user only.
$ErrorActionPreference='Stop'
$mdacProjectRef='xdmcxhvdqsbcqedfprcy'
$mdacCli='C:/Users/wong7768/AppData/Local/npm-cache/_npx/aa8e5c70f9d8d161/node_modules/@supabase/cli-windows-x64/bin/supabase.exe'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$dry=(& $mdacCli db dump --project-ref $mdacProjectRef --workdir "$workspace/work/production-release" --dry-run --output-format json 2>$null|Out-String)
if($LASTEXITCODE -ne 0){throw 'DB_TEMP_CREDENTIAL_REFRESH_FAILED'}
try{
 foreach($key in @('PGHOST','PGPORT','PGUSER','PGPASSWORD','PGDATABASE')){
  $match=[regex]::Match($dry,'(?m)^export '+$key+'="([^"\r\n]*)"')
  if(-not $match.Success){throw 'DB_CREDENTIAL_FIELD_MISSING'}
  [Environment]::SetEnvironmentVariable($key,$match.Groups[1].Value,'Process')
 }
 $direct=$env:PGHOST -eq "db.$mdacProjectRef.supabase.co" -and $env:PGUSER -eq 'cli_login_postgres'
 $pool=$env:PGHOST -eq 'aws-0-ap-southeast-1.pooler.supabase.com' -and $env:PGUSER -eq "cli_login_postgres.$mdacProjectRef" -and $env:PGPORT -eq '5432'
 if((-not $direct -and -not $pool) -or $env:PGDATABASE -ne 'postgres'){throw 'DB_TARGET_MISMATCH'}
 $env:PGSSLMODE='require';$env:PGCONNECT_TIMEOUT='15';$env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=15000'
 $mdacPgBin="$workspace/work/isolated-acceptance/pgsql/bin"
}finally{$dry=$null;$match=$null}
