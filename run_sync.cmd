@echo off
rem Windows wrapper: runs sync.py and appends the full output to a
rem per-day log file (sync-YYYY-MM-DD.log). Called by Task Scheduler.
rem
rem Important: Task Scheduler launches tasks in a limited non-interactive
rem session that does NOT inherit the user's PATH. A `python` binary that
rem works fine from your normal cmd prompt will silently fail when the
rem same task runs under Task Scheduler, with exit code 9020 ("The system
rem cannot execute the specified program").
rem
rem To avoid that, we ALWAYS prefer the venv's python.exe by absolute
rem path (no PATH lookup needed). Falls back to PATH-based `python` only
rem if no venv exists — that fallback works for interactive runs but
rem will fail under Task Scheduler unless python.exe is in the SYSTEM
rem PATH (not just the user PATH).

setlocal
set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

rem --- optional date args (positional):
rem     run_sync                          -> default: SYNC_WINDOW_DAYS from .env
rem     run_sync YYYY-MM-DD               -> sync just that date
rem     run_sync YYYY-MM-DD YYYY-MM-DD    -> sync a date range
rem --- Task Scheduler calls this with no args, so the scheduled path is
rem --- unchanged. This is purely an ergonomics upgrade for manual runs.
set SYNC_ARGS=
set FROM_ARG=%~1
set TO_ARG=%~2

if "%FROM_ARG%"=="" goto :args_done

echo %FROM_ARG% | findstr /r /c:"^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$" >nul
if errorlevel 1 goto :bad_from
if "%TO_ARG%"=="" set TO_ARG=%FROM_ARG%
echo %TO_ARG% | findstr /r /c:"^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$" >nul
if errorlevel 1 goto :bad_to
set SYNC_ARGS=--from %FROM_ARG% --to %TO_ARG%
goto :args_done

:bad_from
echo Bad first date: %FROM_ARG% ^(expected YYYY-MM-DD^)
echo Usage: run_sync [YYYY-MM-DD [YYYY-MM-DD]]
endlocal & exit /b 1

:bad_to
echo Bad second date: %TO_ARG% ^(expected YYYY-MM-DD^)
echo Usage: run_sync [YYYY-MM-DD [YYYY-MM-DD]]
endlocal & exit /b 1

:args_done

rem --- time-based rotation: one log file per day (sync-YYYY-MM-DD.log).
rem --- PowerShell gives us a locale-independent date; the raw %date%
rem --- variable is unusable because its format (MM/dd/yyyy vs dd/MM/yyyy
rem --- vs yyyy-MM-dd, with or without a weekday prefix) depends on the
rem --- Regional Settings of whoever provisioned the VM.
for /f "usebackq" %%i in (`powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"`) do set TODAY=%%i
set LOG_FILE=sync-%TODAY%.log

rem --- retention: delete daily logs older than MAX_DAYS.
rem --- forfiles /d -N matches files last modified N or more days ago;
rem --- the redirect swallows "no files found" on the first few runs.
set MAX_DAYS=30
forfiles /p . /m sync-*.log /d -%MAX_DAYS% /c "cmd /c del @path" >nul 2>&1

echo. >> %LOG_FILE%
echo ======== %date% %time% ======== >> %LOG_FILE%
if "%SYNC_ARGS%"=="" (
    echo [info] mode: default ^(SYNC_WINDOW_DAYS from .env^) >> %LOG_FILE%
) else (
    echo [info] mode: %SYNC_ARGS% >> %LOG_FILE%
)

if exist ".venv\Scripts\python.exe" (
    echo [info] using .venv\Scripts\python.exe >> %LOG_FILE%
    ".venv\Scripts\python.exe" sync.py %SYNC_ARGS% >> %LOG_FILE% 2>&1
) else (
    echo [info] no .venv found -- falling back to PATH python >> %LOG_FILE%
    echo [info] WARNING: this will fail under Task Scheduler unless >> %LOG_FILE%
    echo [info] python.exe is in the SYSTEM PATH, not just user PATH. >> %LOG_FILE%
    echo [info] Recommended: run "python -m venv .venv" then >> %LOG_FILE%
    echo [info] ".venv\Scripts\pip install -r requirements.txt" >> %LOG_FILE%
    python sync.py %SYNC_ARGS% >> %LOG_FILE% 2>&1
)

echo ======== exit code: %ERRORLEVEL% ======== >> %LOG_FILE%
endlocal
