@echo off
title SmartScale AI Demo Launcher
cd /d "%~dp0"
if exist "aws-keda-eks-autoscaling\application\dashboard.py" (
    cd "aws-keda-eks-autoscaling"
)

echo ========================================================
echo        SmartScale AI - Live Presentation Launcher
echo ========================================================
echo.

:: 1. Free up port 8092 if previously running
for /f "tokens=5" %%a in ('netstat -aon ^| findstr ":8092" ^| findstr "LISTENING"') do (
    echo Stopping previous instance on port 8092 (PID: %%a)...
    taskkill /f /pid %%a >nul 2>&1
)

:: 2. Launch Docker Desktop if not running (in background)
echo Checking Docker Desktop...
powershell -Command "Get-Process Docker* -ErrorAction SilentlyContinue" >nul 2>&1
if %errorlevel% neq 0 (
    echo Starting Docker Desktop in background...
    start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
)

:: 3. Launch Dashboard with AWS credentials loaded from .env
echo.
echo Launching SmartScale AI Dashboard (Online AWS Mode)...
start "SmartScale AI Dashboard" cmd /k "python application\dashboard.py"

:: 4. Wait 3 seconds and open the browser
timeout /t 3 /nobreak >nul
echo Opening Dashboard in browser...
start http://localhost:8092

echo.
echo ========================================================
echo Dashboard is running at http://localhost:8092
echo Keep the "SmartScale AI Dashboard" window open during demo!
echo ========================================================
pause
