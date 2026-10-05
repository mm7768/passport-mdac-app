param([Parameter(Mandatory)][int[]]$WorkerProcessIds,[Parameter(Mandatory)][string[]]$HeartbeatIds,[Parameter(Mandatory)][string]$BackupDirectory,[Parameter(Mandatory)][string]$RequiredDbFingerprint,[Parameter(Mandatory)][string[]]$AllowedDeploymentIds,[Parameter(Mandatory)][string]$WorkerWorkingDirectory,[ValidateRange(1,60)][int]$Minutes=15)
$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
Import-Module "$PSScriptRoot/ProductionProbes.psm1" -Force
$root='C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance'
$task=Get-ScheduledTask -TaskName 'MDAC Maintenance Supervisor'
$info=Get-ScheduledTaskInfo -TaskName $task.TaskName
$live=Get-Content -Raw -LiteralPath "$root/supervisor-liveness.json"|ConvertFrom-Json
if($info.LastTaskResult -ne 0 -or [DateTimeOffset]$live.checked_utc -lt [DateTimeOffset]::UtcNow.AddSeconds(-90) -or $live.user -ne [Security.Principal.WindowsIdentity]::GetCurrent().Name){throw 'Independent supervisor liveness/user not verified'}
if($RequiredDbFingerprint -notmatch '^[a-f0-9]{32}$' -or @($AllowedDeploymentIds|Where-Object {$_ -notmatch '^dpl_[A-Za-z0-9]+$'}).Count){throw 'Unapproved target manifest format'}
if($HeartbeatIds.Count -ne 5 -or @($HeartbeatIds|Select-Object -Unique).Count -ne 5){throw 'Five exact worker heartbeat IDs required'}
foreach($file in Get-ChildItem $root -Filter 'run-*.dpapi'){
 if((Read-MdacState $file.FullName).phase -notin @('RESUMED','ABORTED')){throw 'Existing nonterminal maintenance run; reconcile first'}
}
$backup=[IO.Path]::GetFullPath($BackupDirectory).Replace('\','/')
if(-not ($backup+'/').StartsWith('C:/Users/wong7768/Documents/Codex/mdac-private-backups/',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath "$backup/summary.json")){throw 'Verified backup manifest required'}
$backupSummary=Get-Content -LiteralPath "$backup/summary.json" -Raw|ConvertFrom-Json
if($backupSummary.project -ne 'xdmcxhvdqsbcqedfprcy'){throw 'Wrong backup project'}
$rows=@(foreach($id in $WorkerProcessIds){
 $row=Get-MdacProcessIdentity $id
 if(-not $row -or $row.exe -notlike '*python.exe' -or $row.command_line -notmatch '(services[/\\](mdac-fill-preview|registration-check-worker|visit-pass-check-worker|gmail-pin-worker)[/\\]worker\.py|worker[/\\]azure_ocr_worker\.py)'){throw 'Not an approved current worker process'}
 $row.pause_state='NONE';$row.resume_state='NONE';$row.resumed_utc=$null;$row
})
if(-not (Test-Path -LiteralPath $WorkerWorkingDirectory -PathType Container)){throw 'Recorded worker working directory missing'}
if($rows.Count -ne 10 -or @($rows.pid|Select-Object -Unique).Count -ne 10){throw 'Expected five current parent/child worker groups; inspect changed launch topology manually'}
$db=Get-MdacDatabaseProbe;$site=Get-MdacWebsiteProbe
if(-not $db.business_read_ok -or -not $site.ready -or -not $site.login_ok){throw 'Initial production read/version probes failed'}
foreach($id in $HeartbeatIds){if(-not @($db.rows|Where-Object {$_.worker_id -eq $id -and $_.status -in @('ONLINE','BUSY') -and [DateTimeOffset]$_.last_seen_at -gt [DateTimeOffset]::UtcNow.AddMinutes(-3)}).Count){throw 'Initial worker heartbeat not fresh'}}
$run=[guid]::NewGuid().ToString();$path="$root/run-$run.dpapi"
$state=@{run_id=$run;phase='PREPARING';deadline_utc=[DateTime]::UtcNow.AddMinutes($Minutes).ToString('o');updated_utc='';reason='';operator=[Security.Principal.WindowsIdentity]::GetCurrent().Name;project='xdmcxhvdqsbcqedfprcy';rows=$rows;heartbeat_ids=$HeartbeatIds;backup_directory=$backup;worker_working_directory=[IO.Path]::GetFullPath($WorkerWorkingDirectory);baseline_db_fingerprint=$db.fingerprint;baseline_deployment=$site.deployment_id;required_db_fingerprint=$RequiredDbFingerprint;allowed_deployments=$AllowedDeploymentIds;resume_started_utc=$null;events=@();manual_start='Invoke Restart-MissingWorker.ps1 using the original parent PID and this run file. It checks the sealed original command, recorded working directory and absence of any current matching group. No blind use of an old PID.'}
Set-MdacPhase $state 'PREPARING';Save-MdacState $state $path
Write-Output "Prepared only; no processes paused. Run file: $path"
Write-Output 'Before Pause: approve target fingerprint/deployment compatibility, verify fresh backup, set a human deadline reminder. Local logs are not remote notifications.'
