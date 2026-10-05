param([string]$StateRoot='C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance',[switch]$ProbeOnly)
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
Import-Module "$PSScriptRoot/ProductionProbes.psm1" -Force
$allowed='C:/Users/wong7768/Documents/Codex/mdac-private-backups/'
$resolved=[IO.Path]::GetFullPath($StateRoot).Replace('\','/')
if(-not ($resolved+'/').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected supervisor state directory'}
[void][IO.Directory]::CreateDirectory($resolved)
if($ProbeOnly){
 $db=Get-MdacDatabaseProbe;$site=Get-MdacWebsiteProbe
 @{checked_utc=[DateTime]::UtcNow.ToString('o');db_fingerprint=$db.fingerprint;business_read_ok=$db.business_read_ok;website=$site;heartbeat_count=$db.rows.Count;scope='read-only probes; no worker process control'}|ConvertTo-Json -Depth 5
 exit
}
# Task scheduler liveness remains observable with no active maintenance and no DB requests.
[IO.File]::WriteAllText((Join-Path $resolved 'supervisor-liveness.json'),(@{checked_utc=[DateTime]::UtcNow.ToString('o');pid=$PID;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;scope='local independent supervisor'}|ConvertTo-Json))
foreach($file in Get-ChildItem -LiteralPath $resolved -Filter 'run-*.dpapi' -File){
 $lock=$null
 try{
  try{$lock=[IO.File]::Open("$($file.FullName).lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{continue}
  $state=Read-MdacState $file.FullName
  [void](Invoke-MdacRecovery $state $file.FullName {Get-MdacDatabaseProbe} {Get-MdacWebsiteProbe} {param($id)Get-MdacProcessIdentity $id} {param($row)Set-MdacNativeProcess $row Resume} {Get-MdacDatabaseProbe})
 }catch{
  [IO.File]::WriteAllText("$($file.FullName).error.txt",'Supervisor cannot read/process this run. Manual inspection required. Raw secrets/errors are intentionally not logged.')
 }finally{if($lock){$lock.Dispose()}}
}
