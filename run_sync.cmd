@echo off
rem Windows wrapper: runs sync.py and appends the full output to sync.log.
rem Called by Task Scheduler.
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

echo. >> sync.log
echo ======== %date% %time% ======== >> sync.log

if exist ".venv\Scripts\python.exe" (
    echo [info] using .venv\Scripts\python.exe >> sync.log
    ".venv\Scripts\python.exe" sync.py %* >> sync.log 2>&1
) else (
    echo [info] no .venv found -- falling back to PATH python >> sync.log
    echo [info] WARNING: this will fail under Task Scheduler unless >> sync.log
    echo [info] python.exe is in the SYSTEM PATH, not just user PATH. >> sync.log
    echo [info] Recommended: run "python -m venv .venv" then >> sync.log
    echo [info] ".venv\Scripts\pip install -r requirements.txt" >> sync.log
    python sync.py %* >> sync.log 2>&1
)

echo ======== exit code: %ERRORLEVEL% ======== >> sync.log
endlocal
