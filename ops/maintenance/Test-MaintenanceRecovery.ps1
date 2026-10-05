param([string]$EvidencePath=(Join-Path $PSScriptRoot '../../supabase/tests/evidence/20261006/maintenance-fault-tests.json'))
$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
$dir=Join-Path ([IO.Path]::GetTempPath()) ('mdac-watchdog-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$results=[Collections.Generic.List[object]]::new()
function Run-Scenario([string]$Name,[string]$Fault,[string]$Expected){
 $script:calls=0
 $row=@{pid=123;exe='synthetic.exe';created_utc='2026-10-05T00:00:00Z';command_line='synthetic-only';pause_state='PAUSED';resume_state='NONE';resumed_utc=$null}
 $state=@{run_id=[guid]::NewGuid().ToString();phase='PAUSED';deadline_utc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');updated_utc='';reason='';required_db_fingerprint='approved';allowed_deployments=@('old-compatible');rows=@($row);heartbeat_ids=@('synthetic-ocr');resume_started_utc=$null;events=@()}
 $path=Join-Path $dir "$Name.dpapi";Save-MdacState $state $path
 $db={@{fingerprint=if($Fault -in @('partial','unknown','incomplete')){$Fault}else{'approved'};business_read_ok=$true}}
 $site={@{ready=$Fault -ne 'site-failed';login_ok=$true;deployment_id='old-compatible'}}
 $identity={param($id) if($Fault -eq 'missing'){return $null};$actual=$row.Clone();if($Fault -eq 'pid-reused'){$actual.created_utc='2026-10-06T00:00:00Z'};return $actual}
 $resume={param($r)$script:calls++}
 $heart={@{business_read_ok=$true;rows=@(@{worker_id='synthetic-ocr';status=if($Fault -eq 'busy'){'BUSY'}else{'ONLINE'};last_seen_at=if($Fault -eq 'stale'){[DateTime]::UtcNow.AddMinutes(-10).ToString('o')}else{[DateTime]::UtcNow.AddSeconds(1).ToString('o')}})}}
 if($Fault -eq 'interrupted-intent'){$state.rows[0].resume_state='INTENT';Save-MdacState $state $path}
 if($Fault -eq 'partial-pause'){$state.phase='PREPARING';Save-MdacState $state $path}
 if($Fault -eq 'migration-open'){$state.phase='MIGRATING';$state.baseline_db_fingerprint='approved';Save-MdacState $state $path}
 # Discard original state and reload to simulate loss of chat/process memory.
 $state=Read-MdacState $path
 $state=Invoke-MdacRecovery $state $path $db $site $identity $resume $heart
 if($state.phase -ne $Expected){throw "$Name unexpected phase $($state.phase)"}
 $first=$script:calls
 $state=Invoke-MdacRecovery (Read-MdacState $path) $path $db $site $identity $resume $heart
 if($script:calls -ne $first){throw "$Name duplicate process action"}
 if($Expected -eq 'MANUAL' -and $first -ne 0){throw "$Name unsafe process action"}
 $results.Add(@{name=$Name;passed=$true;phase=$state.phase;resume_calls=$script:calls;reason=$state.reason})
}
Run-Scenario 'session_lost_reload_durable_state' 'none' 'RESUMED'
Run-Scenario 'db_ready_site_failed_manual_policy' 'site-failed' 'MANUAL'
Run-Scenario 'migration_not_complete' 'incomplete' 'MANUAL'
Run-Scenario 'partial_commit' 'partial' 'MANUAL'
Run-Scenario 'unknown_database_state' 'unknown' 'MANUAL'
Run-Scenario 'repeat_resume_no_duplicate' 'none' 'RESUMED'
Run-Scenario 'original_process_missing' 'missing' 'MANUAL'
Run-Scenario 'pid_reused_creation_mismatch' 'pid-reused' 'MANUAL'
Run-Scenario 'busy_fresh_is_healthy' 'busy' 'RESUMED'
Run-Scenario 'stale_online_not_success' 'stale' 'RESUMING'
Run-Scenario 'crash_between_resume_intent_and_confirmation' 'interrupted-intent' 'MANUAL'
Run-Scenario 'session_lost_mid_pause_preparing_state' 'partial-pause' 'RESUMED'
Run-Scenario 'open_migration_baseline_not_completion' 'migration-open' 'MANUAL'
@{passed=$true;checked_utc=[DateTime]::UtcNow.ToString('o');scope='Synthetic adapters and durable DPAPI roundtrip; not production pause';scenarios=$results}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $EvidencePath -Encoding utf8
Write-Output "PASS $($results.Count) maintenance fault scenarios. Temporary encrypted evidence: $dir"
