@echo off
rem Windows wrapper: activates the venv (if any) and runs sync.py.
rem Called by Task Scheduler.
rem
rem Task Scheduler throws away stdout/stderr by default, so silent
rem failures inside sync.py are invisible in the Task Scheduler GUI
rem (it just reports "Task completed" regardless of the Python exit
rem code). To make scheduled runs auditable, this wrapper appends
rem every run's full output to sync.log in the same folder, with a
rem timestamped header and the final exit code.
rem
rem If a virtualenv exists at .venv/ we activate it; otherwise we
rem just call the system-wide python (which works as long as pyzk
rem and requests are pip-installed globally).

setlocal
set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

echo. >> sync.log
echo ======== %date% %time% ======== >> sync.log

if exist ".venv\Scripts\activate.bat" (
    call ".venv\Scripts\activate.bat"
    echo [info] activated .venv >> sync.log
) else (
    echo [info] no .venv found, using system python >> sync.log
)

python sync.py %* >> sync.log 2>&1
echo ======== exit code: %ERRORLEVEL% ======== >> sync.log

endlocal
