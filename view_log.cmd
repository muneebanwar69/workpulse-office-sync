@echo off
rem view_log.cmd -- dump the WorkPulse sync log for a given day.
rem
rem Usage:
rem   view_log                  today's log
rem   view_log yesterday        yesterday's log
rem   view_log 2026-07-05       a specific date (YYYY-MM-DD)
rem   view_log list             list all log files, newest first
rem
rem Uses PowerShell for date arithmetic so it's locale-independent --
rem matches how run_sync.cmd derives the log filename.

setlocal
set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

set ARG=%~1

if /i "%ARG%"=="list"      goto :do_list
if "%ARG%"==""             goto :do_today
if /i "%ARG%"=="yesterday" goto :do_yesterday

rem Anything else must look like YYYY-MM-DD.
echo %ARG% | findstr /r /c:"^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$" >nul
if errorlevel 1 goto :bad_arg
set TARGET=%ARG%
goto :show

:do_today
for /f "usebackq" %%i in (`powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"`) do set TARGET=%%i
goto :show

:do_yesterday
for /f "usebackq" %%i in (`powershell -NoProfile -Command "(Get-Date).AddDays(-1).ToString('yyyy-MM-dd')"`) do set TARGET=%%i
goto :show

:do_list
dir /b /o-n sync-*.log 2>nul
if errorlevel 1 echo No log files found.
endlocal & exit /b 0

:bad_arg
echo Unrecognized argument: %ARG%
echo Usage: view_log [^| yesterday ^| YYYY-MM-DD ^| list]
endlocal & exit /b 1

:show
set LOG_FILE=sync-%TARGET%.log
if not exist "%LOG_FILE%" (
    echo No log for %TARGET% ^(expected: %LOG_FILE%^)
    endlocal & exit /b 1
)
type "%LOG_FILE%"
endlocal
