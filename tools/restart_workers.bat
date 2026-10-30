@echo off
setlocal
cd /d "%~dp0\.."

echo [MDAC] Restarting workers...
call "%~dp0stop_workers.bat"
powershell -NoProfile -Command "Start-Sleep -Seconds 2"
call "%~dp0start_workers.bat"
echo [MDAC] Restart completed.
exit /b 0
