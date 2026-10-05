$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
$taskName='MDAC Maintenance Fault Rehearsal'
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'Rehearsal task exists; inspect first'}
$root='C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance-rehearsal/'+[guid]::NewGuid().ToString('N')
[void][IO.Directory]::CreateDirectory($root)
$pwsh=(Get-Command pwsh.exe).Source
$args='-NoProfile -NonInteractive -File "'+(Join-Path $PSScriptRoot 'SyntheticWorker.ps1')+'" -HeartbeatPath "'+$root+'/heartbeat.txt"'
$dummy=Start-Process -FilePath $pwsh -ArgumentList $args -WindowStyle Hidden -PassThru
try{
 for($i=0;$i -lt 10 -and -not (Test-Path "$root/heartbeat.txt");$i++){Start-Sleep -Milliseconds 300}
 if(-not (Test-Path "$root/heartbeat.txt")){throw 'Dummy not running'}
 $row=Get-MdacProcessIdentity $dummy.Id;$row.pause_state='INTENT';$row.resume_state='NONE';$row.resumed_utc=$null
 $state=@{run_id=[guid]::NewGuid().ToString();phase='PAUSED';deadline_utc=[DateTime]::UtcNow.AddSeconds(10).ToString('o');updated_utc='';reason='';required_db_fingerprint='synthetic-approved';allowed_deployments=@('synthetic-site');rows=@($row);heartbeat_ids=@('dummy');resume_started_utc=$null;events=@()}
 Save-MdacState $state "$root/run.dpapi"
 $args='-NoProfile -NonInteractive -File "'+(Join-Path $PSScriptRoot 'Invoke-IndependentRehearsal.ps1')+'" -Root "'+$root+'"'
 $a=New-ScheduledTaskAction -Execute $pwsh -Argument $args -WorkingDirectory $PSScriptRoot
 $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval ([TimeSpan]::FromMinutes(1))
 $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
 $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(1))
 [void](Register-ScheduledTask -TaskName $taskName -Action $a -Trigger $trigger -Principal $principal -Settings $settings)
 Set-MdacNativeProcess $row Pause;$row.pause_state='PAUSED';Save-MdacState $state "$root/run.dpapi"
 Write-Output "Synthetic process suspended. This setup session now exits. Independent task run directory: $root"
}catch{
 if($dummy -and -not $dummy.HasExited){try{Set-MdacNativeProcess (Get-MdacProcessIdentity $dummy.Id) Resume}catch{};Stop-Process -Id $dummy.Id}
 throw
}
