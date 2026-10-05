Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
function Save-MdacState($State,[string]$Path){
 $State.updated_utc=[DateTime]::UtcNow.ToString('o')
 $plain=[Text.Encoding]::UTF8.GetBytes(($State|ConvertTo-Json -Depth 20))
 $encrypted=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
 $tmp="$Path.new";[IO.File]::WriteAllBytes($tmp,$encrypted);[IO.File]::Move($tmp,$Path,$true)
 [Array]::Clear($plain,0,$plain.Length)
 $public=@{run_id=$State.run_id;phase=$State.phase;deadline_utc=$State.deadline_utc;updated_utc=$State.updated_utc;reason=$State.reason;notification='Local status/log only; no external messages. Check status.json at deadline.'}
 [IO.File]::WriteAllText("$Path.status.json",($public|ConvertTo-Json))
}
function Read-MdacState([string]$Path){
 $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
 try{return [Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($plain,0,$plain.Length)}
}
function Set-MdacPhase($State,[string]$Phase,[string]$Reason=''){
 $State.phase=$Phase;$State.reason=$Reason
 $State.events+=@{at=[DateTime]::UtcNow.ToString('o');phase=$Phase;reason=$Reason}
}
function Test-MdacIdentity($Expected,$Actual){
 if(-not $Actual){return $false}
 return ([int]$Expected.pid -eq [int]$Actual.pid -and
  [string]$Expected.exe -eq [string]$Actual.exe -and
  ([DateTimeOffset]$Expected.created_utc).UtcTicks -eq ([DateTimeOffset]$Actual.created_utc).UtcTicks -and
  [string]$Expected.command_line -eq [string]$Actual.command_line)
}
function Invoke-MdacRecovery($State,[string]$Path,[scriptblock]$DbProbe,[scriptblock]$SiteProbe,[scriptblock]$IdentityProbe,[scriptblock]$ResumeProcess,[scriptblock]$HeartbeatProbe,[switch]$ForceDeadline){
 # Caller owns an exclusive file lock. Every side effect has a durable intent.
 if($State.phase -in @('RESUMED','ABORTED','MANUAL')){return $State}
 if($State.phase -eq 'PREPARING' -and -not @($State.rows|Where-Object {$_.pause_state -ne 'NONE'}).Count){return $State}
 if(-not $ForceDeadline -and [DateTimeOffset]::UtcNow -lt [DateTimeOffset]$State.deadline_utc){return $State}
 try{
  $db=& $DbProbe
  if(($db.ContainsKey('migration_in_progress') -and $db.migration_in_progress) -or
    ($State.phase -eq 'MIGRATING' -and $State.ContainsKey('baseline_db_fingerprint') -and $State.required_db_fingerprint -eq $State.baseline_db_fingerprint)){throw 'MIGRATION_IN_PROGRESS_OR_COMPLETION_UNPROVEN'}
  if(-not $db.business_read_ok -or $db.fingerprint -ne $State.required_db_fingerprint){throw 'DB_NOT_APPROVED_OR_INCOMPLETE'}
  Set-MdacPhase $State 'DB_VERIFIED';Save-MdacState $State $Path
  $site=& $SiteProbe
  # Conservative policy: DB ready + failed/unapproved Website => manual. Never auto-start.
  if(-not $site.ready -or -not $site.login_ok -or $site.deployment_id -notin $State.allowed_deployments){throw 'SITE_NOT_APPROVED_OR_FAILED'}
  Set-MdacPhase $State 'SITE_VERIFIED';Save-MdacState $State $Path
  # Preflight ALL identities before touching ANY process (including parent+child groups).
  foreach($row in $State.rows){
   if(-not (Test-MdacIdentity $row (& $IdentityProbe $row.pid))){throw 'PROCESS_MISSING_OR_IDENTITY_CHANGED_MANUAL_START_REQUIRED'}
   if($row.resume_state -eq 'INTENT'){throw 'INTERRUPTED_RESUME_INTENT_MANUAL_RECONCILIATION_REQUIRED'}
  }
  Set-MdacPhase $State 'RESUMING';Save-MdacState $State $Path
  foreach($row in $State.rows){
   if($row.pause_state -eq 'NONE' -or $row.resume_state -eq 'DONE'){continue}
   $row.resume_state='INTENT';Save-MdacState $State $Path
   & $ResumeProcess $row
   $row.resume_state='DONE';$row.resumed_utc=[DateTime]::UtcNow.ToString('o');Save-MdacState $State $Path
  }
  if(-not $State.resume_started_utc){$State.resume_started_utc=[DateTime]::UtcNow.ToString('o');Save-MdacState $State $Path}
  $heartbeat=& $HeartbeatProbe
  if(-not $heartbeat.business_read_ok){throw 'POST_RESUME_BUSINESS_READ_FAILED'}
  $allFresh=$true
  foreach($id in $State.heartbeat_ids){
   $h=@($heartbeat.rows|Where-Object {$_.worker_id -eq $id})
   if($h.Count -ne 1 -or $h[0].status -notin @('ONLINE','BUSY') -or
      [DateTimeOffset]$h[0].last_seen_at -le [DateTimeOffset]$State.resume_started_utc -or
      [DateTimeOffset]$h[0].last_seen_at -lt [DateTimeOffset]::UtcNow.AddMinutes(-3)){$allFresh=$false}
  }
  if($allFresh){Set-MdacPhase $State 'RESUMED';Save-MdacState $State $Path}
  elseif([DateTimeOffset]::UtcNow -gt ([DateTimeOffset]$State.resume_started_utc).AddMinutes(4)){throw 'NEW_HEARTBEATS_TIMEOUT'}
 }catch{
  # Do not log credentials, command lines, hostnames or raw API errors.
  $reason=if($_.Exception.Message -match '^[A-Z_]+$'){$_.Exception.Message}else{'PROBE_OR_PROCESS_FAILURE_INSPECT_PRIVATELY'}
  Set-MdacPhase $State 'MANUAL' $reason;Save-MdacState $State $Path
 }
 return $State
}
function Get-MdacProcessIdentity([int]$ProcessId){
 $p=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
 if(-not $p){return $null}
 Initialize-MdacNative
 $h=[MdacGuardProcess]::OpenProcess(0x1000,$false,$ProcessId)
 if($h -eq [IntPtr]::Zero){throw 'PROCESS_QUERY_HANDLE_FAILED'}
 try{
  [long]$c=0;[long]$e=0;[long]$k=0;[long]$u=0;$name=[Text.StringBuilder]::new(32768);[int]$n=32768
  if(-not [MdacGuardProcess]::GetProcessTimes($h,[ref]$c,[ref]$e,[ref]$k,[ref]$u) -or -not [MdacGuardProcess]::QueryFullProcessImageName($h,0,$name,[ref]$n)){throw 'PROCESS_QUERY_FAILED'}
  $created=[DateTime]::FromFileTimeUtc($c)
  # CIM creation times lose sub-microsecond precision. Seal exact kernel time,
  # after checking the CIM command belongs to this same handle's process.
  if([Math]::Abs($created.Ticks-$p.CreationDate.ToUniversalTime().Ticks) -gt 10000 -or $name.ToString() -ne $p.ExecutablePath){throw 'PROCESS_QUERY_IDENTITY_CHANGED'}
  return @{pid=$p.ProcessId;parent_pid=$p.ParentProcessId;exe=$name.ToString();created_utc=$created.ToString('o');command_line=$p.CommandLine}
 }finally{[void][MdacGuardProcess]::CloseHandle($h)}
}
function Initialize-MdacNative {
 if(-not ('MdacGuardProcess' -as [type])){
  Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MdacGuardProcess {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint a,bool i,int p);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetProcessTimes(IntPtr h,out long c,out long e,out long k,out long u);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool QueryFullProcessImageName(IntPtr h,uint flags,StringBuilder s,ref int n);
 [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
 [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
}
'@
 }
}
function Set-MdacNativeProcess($Row,[ValidateSet('Pause','Resume')][string]$Action){
 Initialize-MdacNative
 if(-not (Test-MdacIdentity $Row (Get-MdacProcessIdentity $Row.pid))){throw 'PROCESS_IDENTITY_CHANGED'}
 $h=[MdacGuardProcess]::OpenProcess(0x1800,$false,[int]$Row.pid)
 if($h -eq [IntPtr]::Zero){throw 'PROCESS_HANDLE_FAILED'}
 try{
  [long]$c=0;[long]$e=0;[long]$k=0;[long]$u=0;$name=[Text.StringBuilder]::new(32768);[int]$n=32768
  if(-not [MdacGuardProcess]::GetProcessTimes($h,[ref]$c,[ref]$e,[ref]$k,[ref]$u) -or
    -not [MdacGuardProcess]::QueryFullProcessImageName($h,0,$name,[ref]$n) -or
    [DateTime]::FromFileTimeUtc($c).Ticks -ne ([DateTimeOffset]$Row.created_utc).UtcTicks -or $name.ToString() -ne $Row.exe){throw 'HANDLE_IDENTITY_CHANGED'}
  $code=if($Action -eq 'Pause'){[MdacGuardProcess]::NtSuspendProcess($h)}else{[MdacGuardProcess]::NtResumeProcess($h)}
  if($code -ne 0){throw 'NATIVE_PROCESS_CONTROL_FAILED'}
 }finally{[void][MdacGuardProcess]::CloseHandle($h)}
}
Export-ModuleMember -Function *-Mdac*
