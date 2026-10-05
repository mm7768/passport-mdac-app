param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
$allowed='C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance-rehearsal/'
$resolved=[IO.Path]::GetFullPath($Root).Replace('\','/')+'/'
if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Not a local synthetic rehearsal'}
$path=Join-Path $Root 'run.dpapi';$lock=[IO.File]::Open("$path.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 $state=Read-MdacState $path
 foreach($row in $state.rows){if($row.command_line -notlike '*SyntheticWorker.ps1*' -or $row.command_line -notlike "*$Root*"){throw 'Refusing non-synthetic rehearsal process'}}
 $hb={@{business_read_ok=$true;rows=@(@{worker_id='dummy';status='BUSY';last_seen_at=[IO.File]::ReadAllText((Join-Path $Root 'heartbeat.txt'))})}}
 [void](Invoke-MdacRecovery $state $path {@{fingerprint='synthetic-approved';business_read_ok=$true}} {@{ready=$true;login_ok=$true;deployment_id='synthetic-site'}} {param($id)Get-MdacProcessIdentity $id} {param($r)Set-MdacNativeProcess $r Resume} $hb)
 [IO.File]::WriteAllText((Join-Path $Root 'independent-task.json'),(@{at=[DateTime]::UtcNow.ToString('o');supervisor_pid=$PID;phase=(Read-MdacState $path).phase}|ConvertTo-Json))
}finally{$lock.Dispose()}
