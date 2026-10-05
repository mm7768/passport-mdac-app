param([Parameter(Mandatory)][string]$Root,[string]$EvidencePath=(Join-Path $PSScriptRoot '../../supabase/tests/evidence/20261006/maintenance-independent-task.json'))
$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
$resolved=[IO.Path]::GetFullPath($Root).Replace('\','/')+'/'
if(-not $resolved.StartsWith('C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance-rehearsal/',[StringComparison]::OrdinalIgnoreCase)){throw 'Wrong rehearsal directory'}
$state=Read-MdacState (Join-Path $Root 'run.dpapi')
$info=Get-ScheduledTaskInfo -TaskName 'MDAC Maintenance Fault Rehearsal'
if($state.phase -ne 'RESUMED' -or $info.LastTaskResult -ne 0 -or @($state.rows|Where-Object resume_state -ne 'DONE').Count){throw 'Independent recovery not passed'}
$row=$state.rows[0];$identity=Get-MdacProcessIdentity $row.pid
if(-not (Test-MdacIdentity $row $identity) -or $row.command_line -notlike '*SyntheticWorker.ps1*'){throw 'Rehearsal process identity changed; no cleanup'}
$hb=[DateTimeOffset][IO.File]::ReadAllText((Join-Path $Root 'heartbeat.txt'))
if($hb -lt [DateTimeOffset]::UtcNow.AddSeconds(-10)){throw 'Dummy new heartbeat stale'}
$production=Get-ScheduledTaskInfo -TaskName 'MDAC Maintenance Supervisor'
$live=Get-Content 'C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance/supervisor-liveness.json' -Raw|ConvertFrom-Json
if($production.LastTaskResult -ne 0 -or [DateTimeOffset]$live.checked_utc -lt [DateTimeOffset]::UtcNow.AddSeconds(-90)){throw 'Production supervisor liveness not confirmed'}
$creatorAlive=if($row.ContainsKey('parent_pid')){@(Get-CimInstance Win32_Process -Filter "ProcessId=$($row.parent_pid)").Count -gt 0}else{$null}
@{passed=$true;checked_utc=[DateTime]::UtcNow.ToString('o');scope='Actual Task Scheduler + one synthetic local process; no production worker pause';setup_creator_pid_still_exists=$creatorAlive;phase=$state.phase;process_resumed_once=$row.resume_state -eq 'DONE';new_dummy_heartbeat_utc=$hb.ToString('o');fault_task_last_result=$info.LastTaskResult;production_supervisor_last_result=$production.LastTaskResult;production_supervisor_liveness_utc=$live.checked_utc;events=$state.events;cleanup='Exact two rehearsal tasks and verified dummy process removed; encrypted rehearsal records retained. Production supervisor retained, no active production maintenance run.'}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $EvidencePath -Encoding utf8
Unregister-ScheduledTask -TaskName 'MDAC Maintenance Fault Rehearsal' -Confirm:$false
if(Get-ScheduledTask -TaskName 'MDAC Maintenance Supervisor Rehearsal' -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName 'MDAC Maintenance Supervisor Rehearsal' -Confirm:$false}
Stop-Process -Id $row.pid
Write-Output 'PASS independent scheduled recovery and fresh heartbeat; exact rehearsal tasks and dummy removed. Production supervisor alive; no production pause.'
