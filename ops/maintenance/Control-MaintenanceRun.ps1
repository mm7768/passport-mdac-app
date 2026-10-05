param([Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)][ValidateSet('Pause','MigrationStarting','RetryAfterManualReview','Status')][string]$Action)
$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
$root='C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance/'
$resolved=[IO.Path]::GetFullPath($RunPath).Replace('\','/')
if(-not $resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^run-[a-f0-9-]{36}\.dpapi$'){throw 'Not a scoped production maintenance run'}
$lock=[IO.File]::Open("$resolved.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 $state=Read-MdacState $resolved
 if($Action -eq 'Status'){Get-Content "$resolved.status.json";return}
 if($Action -eq 'Pause'){
  if($state.phase -ne 'PREPARING' -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$state.deadline_utc){throw 'Run not prepared or deadline expired'}
  $info=Get-ScheduledTaskInfo -TaskName 'MDAC Maintenance Supervisor'
  $live=Get-Content "$root/supervisor-liveness.json" -Raw|ConvertFrom-Json
  if($info.LastTaskResult -ne 0 -or [DateTimeOffset]$live.checked_utc -lt [DateTimeOffset]::UtcNow.AddSeconds(-90)){throw 'Independent supervisor not alive'}
  foreach($row in $state.rows){if(-not (Test-MdacIdentity $row (Get-MdacProcessIdentity $row.pid))){throw 'Worker identity changed before pause'}}
  foreach($row in $state.rows){
   $row.pause_state='INTENT';Save-MdacState $state $resolved
   Set-MdacNativeProcess $row Pause
   $row.pause_state='PAUSED';Save-MdacState $state $resolved
  }
  Set-MdacPhase $state 'PAUSED';Save-MdacState $state $resolved
 }elseif($Action -eq 'MigrationStarting'){
  if($state.phase -ne 'PAUSED'){throw 'Not PAUSED'}
  Set-MdacPhase $state 'MIGRATING';Save-MdacState $state $resolved
 }else{
  if($state.phase -ne 'MANUAL' -or @($state.rows|Where-Object resume_state -eq 'INTENT').Count){throw 'Manual reconciliation/intent review required; never blindly replay a resume'}
  Set-MdacPhase $state 'PAUSED' 'MANUAL_REVIEW_REQUESTED';$state.deadline_utc=[DateTime]::UtcNow.ToString('o');Save-MdacState $state $resolved
 }
}catch{
 if($state -and $Action -eq 'Pause' -and @($state.rows|Where-Object {$_.pause_state -ne 'NONE'}).Count){
  # A mid-pause failure must be visible to the independent supervisor, not remain PREPARING.
  Set-MdacPhase $state 'PAUSED' 'PARTIAL_PAUSE_REQUIRES_DEADLINE_CHECK';Save-MdacState $state $resolved
 }
 throw
}finally{$lock.Dispose()}
if($Action -eq 'RetryAfterManualReview'){& "$PSScriptRoot/Invoke-MaintenanceSupervisor.ps1"}
