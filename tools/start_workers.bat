@echo off
setlocal
cd /d "%~dp0\.."

set "PYTHON_EXE=C:\Users\Administrator\Documents\Codex\2026-10-25\qi\outputs\mdac-local\.venv\Scripts\pythonw.exe"
if not exist "%PYTHON_EXE%" (
    set "PYTHON_EXE=pythonw.exe"
)

:: Run log maintenance in background
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0maintenance_logs.ps1" >nul 2>&1

:: Check if worker_gui.py is already running
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process -Filter \"CommandLine LIKE '%%worker_gui.py%%'\"; if ($p) { exit 1 } else { exit 0 }"
if %ERRORLEVEL% EQU 1 (
    echo [MDAC] Worker GUI is already running. Skipping startup.
    exit /b 0
)

echo [MDAC] Starting Worker GUI and 5 automation workers...
start "" "%PYTHON_EXE%" tools\worker_gui.py
echo [MDAC] Done.
exit /b 0
