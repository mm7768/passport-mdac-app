# MDAC Worker Watchdog
$running = Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%worker_gui.py%'"
if (-not $running) {
    Write-Host "[WATCHDOG] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Worker GUI not detected. Auto-recovering..."
    Start-Process -FilePath "C:\Users\Administrator\.gemini\antigravity\scratch\passport-mdac-app\tools\start_workers.bat" -WindowStyle Hidden
} else {
    Write-Host "[WATCHDOG] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Worker GUI is healthy (PID: $($running[0].ProcessId))."
}
