@echo off
setlocal

cd /d "%~dp0Lap_Time_Leaderboard"

rem If the server is already running, just open the browser
curl -s -o NUL http://localhost:8000
if not errorlevel 1 (
    echo Server already running, opening browser...
    start "" http://localhost:8000
    exit /b 0
)

rem Find a working Python command
set "PY="
python --version >nul 2>&1
if not errorlevel 1 set "PY=python"

if not defined PY (
    py --version >nul 2>&1
    if not errorlevel 1 set "PY=py"
)

if not defined PY (
    echo [ERROR] Python not found. Install it from https://www.python.org/ and try again.
    pause
    exit /b 1
)

echo Starting leaderboard server...
start "BeamNG Leaderboard Server - close to stop" cmd /k "%PY% server.py"

rem Wait up to 5 seconds for the server to be ready
set /a tries=0
:wait
ping -n 2 127.0.0.1 >nul
curl -s -o NUL http://localhost:8000
if not errorlevel 1 goto ready
set /a tries+=1
if %tries% lss 5 goto wait

echo [ERROR] Server failed to start. Check the server window for the error message.
pause
exit /b 1

:ready
start "" http://localhost:8000
echo Browser opened: http://localhost:8000
echo The server runs in its own window. Close that window to stop it.
ping -n 6 127.0.0.1 >nul
endlocal
exit /b 0
