# MDAC Worker Log Maintenance & Rotation Script
param(
    [int]$MaxSizeMB = 15,
    [int]$MaxAgeDays = 14
)

$targetDirs = @(
    "C:\Users\Administrator\.gemini\antigravity\scratch\passport-mdac-app\logs",
    "C:\Users\Administrator\Documents\Codex\2026-10-25\qi\outputs\mdac-local\logs"
)

$maxBytes = $MaxSizeMB * 1024 * 1024
$now = Get-Date

Write-Host "================ MDAC Log Maintenance ================"
Write-Host "Started at: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Size Threshold: $MaxSizeMB MB | Retention: $MaxAgeDays Days"

foreach ($dir in $targetDirs) {
    if (-not (Test-Path $dir)) { continue }
    Write-Host "`nScanning Directory: $dir"
    
    # 1. Clean old rotated or temp logs
    Get-ChildItem -Path $dir -Recurse -File -Include "*.log.*", "*.tmp", "*.bak" | ForEach-Object {
        if ($_.LastWriteTime -lt $now.AddDays(-$MaxAgeDays)) {
            Write-Host "  [DELETE] Removing expired file: $($_.Name) ($([math]::Round($_.Length/1MB, 2)) MB)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    # 2. Rotate oversized active logs
    Get-ChildItem -Path $dir -Recurse -File -Filter "*.log" | ForEach-Object {
        if ($_.Length -gt $maxBytes) {
            $mb = [math]::Round($_.Length / 1MB, 2)
            Write-Host "  [ROTATE] File $($_.Name) exceeds threshold: $mb MB"
            $backup = "$($_.FullName).1"
            if (Test-Path $backup) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
            try {
                # Copy last 10,000 lines to preserve recent history
                $tail = Get-Content $_.FullName -Tail 10000
                $tail | Set-Content $backup -Encoding UTF8
                # Clear primary file to release disk space
                Clear-Content $_.FullName -ErrorAction SilentlyContinue
                Write-Host "  [OK] Successfully rotated $($_.Name) (preserved last 10k lines in .1)"
            } catch {
                Write-Host "  [WARN] Could not rotate $($_.Name): $($_.Exception.Message)"
            }
        } else {
            Write-Host "  [PASS] $($_.Name) is healthy ($([math]::Round($_.Length/1KB, 1)) KB)"
        }
    }
}

Write-Host "`nLog maintenance completed."
