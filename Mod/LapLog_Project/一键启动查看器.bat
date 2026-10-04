@echo off
setlocal

rem LapLog 分析台一键启动，只读本机 lapLogs 存档。
rem 端口 8010；圈速榜用 8000，两者可同时开。

set "VIEWER=%~dp0LapLog_Viewer"
set "PORT=8010"

rem 服务已在运行就直接开浏览器
curl -s -o NUL http://localhost:%PORT%
if not errorlevel 1 (
    echo Viewer already running, opening browser...
    start "" http://localhost:%PORT%
    exit /b 0
)

rem 找一个可用的 Python
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

echo Starting LapLog viewer server...
start "LapLog Viewer - close to stop" /D "%VIEWER%" cmd /k "%PY% server.py --port %PORT%"

rem 最多等 5 秒
set /a tries=0
:wait
ping -n 2 127.0.0.1 >nul
curl -s -o NUL http://localhost:%PORT%
if not errorlevel 1 goto ready
set /a tries+=1
if %tries% lss 5 goto wait

echo [ERROR] Server failed to start. Check the server window for the error message.
pause
exit /b 1

:ready
start "" http://localhost:%PORT%
echo Browser opened: http://localhost:%PORT%
echo The server runs in its own window. Close that window to stop it.
ping -n 6 127.0.0.1 >nul
endlocal
exit /b 0
