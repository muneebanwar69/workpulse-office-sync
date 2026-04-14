#!/usr/bin/env bash
# Linux wrapper: activates the venv (if any) and runs sync.py.
# Called by systemd (workpulse-sync.service) or by cron.
#
# systemd captures stdout/stderr in journald, but for parity with the
# Windows wrapper this also appends every run's full output to
# sync.log with a timestamped header and the final exit code. Easier
# to grep than journalctl.
#
# If a virtualenv exists at .venv/ we activate it; otherwise we just
# call the system-wide python (which works as long as pyzk and
# requests are pip-installed globally).

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

{
    echo
    echo "======== $(date '+%Y-%m-%d %H:%M:%S') ========"

    if [ -f ".venv/bin/activate" ]; then
        # shellcheck disable=SC1091
        source .venv/bin/activate
        echo "[info] activated .venv"
    else
        echo "[info] no .venv found, using system python"
    fi

    python sync.py "$@"
    echo "======== exit code: $? ========"
} >> sync.log 2>&1
