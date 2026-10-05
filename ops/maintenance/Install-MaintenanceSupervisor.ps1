param([ValidateSet('Install','Remove','Status')][string]$Action='Status',[switch]$Rehearsal)
$ErrorActionPreference='Stop'
$name=if($Rehearsal){'MDAC Maintenance Supervisor Rehearsal'}else{'MDAC Maintenance Supervisor'}
$stateRoot=if($Rehearsal){'C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance-rehearsal'}else{'C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance'}
if($Action -eq 'Remove'){
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($task){Unregister-ScheduledTask -TaskName $name -Confirm:$false}
 Write-Output 'Exact MDAC supervisor task removed; encrypted run state retained.';exit
}
if($Action -eq 'Status'){
 Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue|Select-Object TaskName,State
 Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue|Select-Object LastRunTime,LastTaskResult,NextRunTime
 exit
}
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'Task already exists; inspect before replacing'}
$pwsh=(Get-Command pwsh.exe).Source
$args='-NoProfile -NonInteractive -File "'+(Join-Path $PSScriptRoot 'Invoke-MaintenanceSupervisor.ps1')+'" -StateRoot "'+$stateRoot+'"'
$a=New-ScheduledTaskAction -Execute $pwsh -Argument $args -WorkingDirectory $PSScriptRoot
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1))
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
[void](Register-ScheduledTask -TaskName $name -Action $a -Trigger $trigger -Principal $principal -Settings $settings -Description 'Local MDAC deadline recovery checks. No run => liveness only. Requires this user logged on; no chat dependency; no external notifications.')
Start-ScheduledTask -TaskName $name
Write-Output 'Independent MDAC supervisor registered and dispatched. Verify liveness and last result before ANY production pause.'
