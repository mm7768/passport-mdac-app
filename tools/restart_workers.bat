@echo off
setlocal
cd /d "%~dp0\.."

echo [MDAC] Restarting workers...
call "%~dp0stop_workers.bat"
timeout /t 2 /nobreak >nul
call "%~dp0start_workers.bat"
echo [MDAC] Restart completed.
exit /b 0
