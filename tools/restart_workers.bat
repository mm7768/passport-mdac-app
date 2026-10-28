@echo off
chcp 65001 >nul
title Passport MDAC · Worker 重启管理器
echo ===================================================
echo     Passport MDAC 极简 Worker 服务管理器
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

timeout /t 1 /nobreak >nul

echo [2/3] 正在切换至项目工作目录...
cd /d "%~dp0\.."

set PYTHON_EXE=python
if exist ".venv\Scripts\python.exe" set PYTHON_EXE=.venv\Scripts\python.exe

echo [3/3] 正在启动极简黑色风格 Worker 管理窗口 (带白色呼吸灯)...
start "" "%PYTHON_EXE%" tools/run_all_workers.py

echo ===================================================
echo   ✅ Worker 服务中心已就绪！
echo ===================================================
timeout /t 2 >nul
