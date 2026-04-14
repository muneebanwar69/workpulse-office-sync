@echo off
rem Windows wrapper: activates the venv and runs sync.py.
rem Called by Task Scheduler.

setlocal
set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

if exist ".venv\Scripts\activate.bat" (
    call ".venv\Scripts\activate.bat"
)

python sync.py %*
endlocal
