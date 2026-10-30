@echo off
setlocal
cd /d "%~dp0\.."

set "PYTHON_EXE=C:\Users\Administrator\Documents\Codex\2026-10-25\qi\outputs\mdac-local\.venv\Scripts\python.exe"
if not exist "%PYTHON_EXE%" (
    set "PYTHON_EXE=python.exe"
)

echo [MDAC] Stopping all worker processes and GUI...
"%PYTHON_EXE%" tools\stop_workers.py
echo [MDAC] Stopped.
exit /b 0
