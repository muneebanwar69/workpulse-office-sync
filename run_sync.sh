#!/usr/bin/env bash
# Linux wrapper: activates the venv (if any) and runs sync.py.
# Called by systemd (workpulse-sync.service) or by cron.
#
# systemd captures stdout/stderr in journald, but for parity with the
# Windows wrapper this also appends every run's full output to
# sync.log with a timestamped header and the final exit code. Easier
# to grep than journalctl.
#
# Optional date args (positional):
#     run_sync.sh                          -> default: SYNC_WINDOW_DAYS from .env
#     run_sync.sh YYYY-MM-DD               -> sync just that date
#     run_sync.sh YYYY-MM-DD YYYY-MM-DD    -> sync a date range
# systemd and cron invoke this with no args, so the scheduled path is
# unchanged. This is purely an ergonomics upgrade for manual runs.
#
# If a virtualenv exists at .venv/ we activate it; otherwise we just
# call the system-wide python (which works as long as pyzk and
# requests are pip-installed globally).

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# --- Parse optional date args ----------------------------------------
# Bad-arg messages go to stderr (visible to the human running the
# command) BEFORE the sync.log redirect block starts, so a typo is
# never hidden inside the log file.
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
SYNC_ARGS=()
if [ $# -ge 1 ]; then
    if ! [[ $1 =~ $DATE_RE ]]; then
        echo "Bad first date: $1 (expected YYYY-MM-DD)" >&2
        echo "Usage: run_sync.sh [YYYY-MM-DD [YYYY-MM-DD]]" >&2
        exit 1
    fi
    if [ $# -ge 2 ] && ! [[ $2 =~ $DATE_RE ]]; then
        echo "Bad second date: $2 (expected YYYY-MM-DD)" >&2
        echo "Usage: run_sync.sh [YYYY-MM-DD [YYYY-MM-DD]]" >&2
        exit 1
    fi
    FROM_ARG=$1
    TO_ARG=${2:-$1}
    SYNC_ARGS=(--from "$FROM_ARG" --to "$TO_ARG")
fi

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

    if [ ${#SYNC_ARGS[@]} -eq 0 ]; then
        echo "[info] mode: default (SYNC_WINDOW_DAYS from .env)"
    else
        echo "[info] mode: ${SYNC_ARGS[*]}"
    fi

    python sync.py "${SYNC_ARGS[@]}"
    echo "======== exit code: $? ========"
} >> sync.log 2>&1
