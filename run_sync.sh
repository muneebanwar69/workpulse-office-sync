#!/usr/bin/env bash
# Linux wrapper: activates the venv and runs sync.py.
# Called by systemd (workpulse-sync.service) or by cron.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Activate venv if present (created during setup: python3 -m venv .venv)
if [ -f ".venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source .venv/bin/activate
fi

exec python sync.py "$@"
