@echo off
chcp 65001 >nul
echo ===================================================
echo     正在重启 MDAC ^& Visit Pass 自动核验 Worker
echo ===================================================

echo [1/3] 正在终止旧版常驻 Python Worker 进程...
taskkill /F /FI "WINDOWTITLE eq *Visit Pass*" /T >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq *Registration*" /T >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq *MDAC*" /T >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq *Azure 护照 OCR*" /T >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq *Gmail PIN*" /T >nul 2>&1
wmic process where "commandline like '%%visit-pass-check-worker%%' and name='python.exe'" call terminate >nul 2>&1
wmic process where "commandline like '%%registration-check-worker%%' and name='python.exe'" call terminate >nul 2>&1
wmic process where "commandline like '%%mdac-fill-preview%%' and name='python.exe'" call terminate >nul 2>&1
wmic process where "commandline like '%%azure_ocr_worker%%' and name='python.exe'" call terminate >nul 2>&1
wmic process where "commandline like '%%gmail-pin-worker%%' and name='python.exe'" call terminate >nul 2>&1

timeout /t 2 /nobreak >nul

echo [2/3] 正在加载最新代码 (v1.0.22 增强版)...
cd /d "C:\Users\wong7768\.gemini\antigravity\scratch\passport-mdac-app"

set PYTHON_EXE=C:\Users\wong7768\PyCharmMiscProject\3.13.venv\Scripts\python.exe

echo [3/3] 正在以多标签页模式调起 Windows Terminal...
start "" "%PYTHON_EXE%" tools/launch_wt_workers.py --mode tabs

echo ===================================================
echo   ✅ 所有 Worker 已成功以最新代码重新启动！
echo ===================================================
pause
