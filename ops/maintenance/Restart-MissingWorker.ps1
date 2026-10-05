param([Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)][int]$OriginalParentPid)
$ErrorActionPreference='Stop';Import-Module "$PSScriptRoot/MdacMaintenance.psm1" -Force
Import-Module "$PSScriptRoot/ProductionProbes.psm1" -Force
$resolved=[IO.Path]::GetFullPath($RunPath).Replace('\','/')
if(-not $resolved.StartsWith('C:/Users/wong7768/Documents/Codex/mdac-private-backups/maintenance/',[StringComparison]::OrdinalIgnoreCase)){throw 'Wrong run scope'}
$lock=[IO.File]::Open("$resolved.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 $state=Read-MdacState $resolved
 if($state.phase -ne 'MANUAL'){throw 'Manual state required'}
 $row=@($state.rows|Where-Object {$_.pid -eq $OriginalParentPid})
 if($row.Count -ne 1 -or $row[0].parent_pid -in $state.rows.pid){throw 'Select the original group parent, not a child PID'}
 $row=$row[0]
 # Native Windows parser preserves quoting; arguments never go through a shell.
 Add-Type @'
using System;using System.Runtime.InteropServices;
public static class MdacArgv { [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CommandLineToArgvW(string s,out int n);[DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p); }
'@
 [int]$count=0;$ptr=[MdacArgv]::CommandLineToArgvW($row.command_line,[ref]$count)
 if($ptr -eq [IntPtr]::Zero){throw 'Original command parse failed'}
 try{$argv=@(for($i=0;$i -lt $count;$i++){[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($ptr,$i*[IntPtr]::Size))})}finally{[void][MdacArgv]::LocalFree($ptr)}
 if($count -lt 2 -or $row.exe -notlike '*python.exe'){throw 'Not an original Python worker launch'}
 $scriptArg=@($argv|Where-Object {$_ -match '(services[/\\](mdac-fill-preview|registration-check-worker|visit-pass-check-worker|gmail-pin-worker)[/\\]worker\.py|worker[/\\]azure_ocr_worker\.py)$'})
 if($scriptArg.Count -ne 1){throw 'Original worker script ambiguous'}
 $group=[regex]::Match($scriptArg[0],'(services[/\\](mdac-fill-preview|registration-check-worker|visit-pass-check-worker|gmail-pin-worker)[/\\]worker\.py|worker[/\\]azure_ocr_worker\.py)$').Value.Replace('\','/')
 $scriptPath=if([IO.Path]::IsPathRooted($scriptArg[0])){[IO.Path]::GetFullPath($scriptArg[0])}else{[IO.Path]::GetFullPath((Join-Path $state.worker_working_directory $scriptArg[0]))}
 $launchRoot=([IO.Path]::GetFullPath($state.worker_working_directory).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar)
 if(-not $scriptPath.StartsWith($launchRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Original script outside recorded worker source root or missing'}
 $current=@(Get-CimInstance Win32_Process -Filter "Name='python.exe'"|Where-Object {$_.CommandLine -and $_.CommandLine.Replace('\','/').IndexOf($group,[StringComparison]::OrdinalIgnoreCase) -ge 0})
 if($current.Count){throw 'Matching group already exists (possibly paused); no duplicate start allowed'}
 $db=Get-MdacDatabaseProbe;$site=Get-MdacWebsiteProbe
 if(-not $db.business_read_ok -or $db.fingerprint -ne $state.required_db_fingerprint -or -not $site.ready -or -not $site.login_ok -or $site.deployment_id -notin $state.allowed_deployments){throw 'Version/normal read gates failed'}
 if(-not (Test-Path -LiteralPath $row.exe) -or -not (Test-Path -LiteralPath $state.worker_working_directory)){throw 'Original launch paths missing'}
 $start=[Diagnostics.ProcessStartInfo]::new($row.exe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$state.worker_working_directory
 foreach($arg in $argv[1..($argv.Count-1)]){$start.ArgumentList.Add($arg)}
 # Durable intent makes a crash visible; repeated invocation rechecks matching group.
 Set-MdacPhase $state 'MANUAL' 'MISSING_GROUP_START_INTENT';Save-MdacState $state $resolved
 $new=[Diagnostics.Process]::Start($start)
 $state.events+=@{at=[DateTime]::UtcNow.ToString('o');phase='MANUAL';reason='RECORDED_SINGLE_GROUP_STARTED';new_pid=$new.Id;original_parent_pid=$OriginalParentPid}
 Save-MdacState $state $resolved
 Write-Output 'One original missing worker group launched. Remains MANUAL until new exact process roster, five NEW heartbeats and business reads are verified; do not relaunch blindly.'
}finally{$lock.Dispose()}
