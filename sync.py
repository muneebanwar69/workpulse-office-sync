#!/usr/bin/env python3
"""
WorkPulse Office Sync -- one-file script.

Runs on a machine that has LAN access to the ZKTeco K60 (e.g. a small
VM on the office Proxmox). Pulls punches from the device, logs in to
the WorkPulse production backend, and POSTs them to the shift-aware
/api/v1/attendance/backfill endpoint so every employee's timesheet
stays up-to-date.

Completely self-contained. Only Python stdlib + two pip packages:
    pip install pyzk requests

Typical usage:

    # One-shot: sync today (what cron / task scheduler will run)
    python sync.py

    # Arbitrary range
    python sync.py --from 2026-04-01 --to 2026-04-13

    # Dry-run: pull from device + summarize, do NOT post to backend
    python sync.py --dry-run

    # Continuous loop: poll every 5 minutes, never exit
    python sync.py --loop 300

Configuration is read from environment variables (put them in .env
next to the script -- the script auto-loads .env on startup):

    WORKPULSE_API            https://hcm-api.owesome.work     (default)
    WORKPULSE_EMAIL          sync-bot@example.com             (required)
    WORKPULSE_PASSWORD       ********                         (required)
    WORKPULSE_COMPANY_ID     1                                (default 1)
    DEVICE_IP                192.168.101.247                  (default)
    DEVICE_PORT              4370                             (default)
    SYNC_WINDOW_DAYS         1      (0 = today only, 1 = yesterday+today)

CLI flags override env vars. See --help for all options.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from datetime import date, datetime, timedelta
from typing import Optional

# -- Defaults ---------------------------------------------------------

DEFAULT_API = "https://hcm-api.owesome.work"
DEFAULT_DEVICE_IP = "192.168.101.247"
DEFAULT_DEVICE_PORT = 4370
DEFAULT_COMPANY_ID = 1

log = logging.getLogger("workpulse-sync")


# -- .env loader (no dotenv dependency) -------------------------------


def _load_env_file(path: str) -> None:
    """Minimal .env loader: KEY=VALUE lines, ignores comments and blanks.
    Values already set in os.environ are NOT overridden."""
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = val


# -- Device I/O -------------------------------------------------------


def pull_all_punches(ip: str, port: int) -> list[dict]:
    """Connect to the ZKTeco device and pull every attendance log it has."""
    try:
        from zk import ZK
    except ImportError:
        log.error("pyzk is not installed. Run: pip install pyzk")
        sys.exit(2)

    log.info("Connecting to ZKTeco at %s:%d ...", ip, port)
    try:
        conn = ZK(ip, port=port, timeout=30).connect()
    except Exception as e:
        log.error("Failed to connect to device: %s", e)
        sys.exit(3)

    try:
        info = {
            "name": conn.get_device_name(),
            "serial": conn.get_serialnumber(),
            "firmware": conn.get_firmware_version(),
            "users": len(conn.get_users()),
        }
        log.info("Device: %s", info)

        log.info("Pulling attendance logs (may take ~10s for 100k+ rows)...")
        all_logs = conn.get_attendance()
        log.info("Pulled %d punches from device", len(all_logs))

        return [
            {
                "user_id": str(a.user_id),
                "timestamp": a.timestamp.isoformat(),
                "status": int(getattr(a, "status", 0) or 0),
            }
            for a in all_logs
        ]
    finally:
        try:
            conn.disconnect()
        except Exception:
            pass


# -- Helpers ----------------------------------------------------------


def detect_range(punches: list[dict]) -> tuple[date, date]:
    """Return (earliest, latest) punch date from the pool."""
    if not punches:
        today = date.today()
        return today, today
    lo = min(p["timestamp"] for p in punches)
    hi = max(p["timestamp"] for p in punches)
    return datetime.fromisoformat(lo).date(), datetime.fromisoformat(hi).date()


def filter_by_range(punches: list[dict], from_d: date, to_d: date) -> list[dict]:
    """Keep punches whose calendar date is inside [from_d-1, to_d+1].
    The 1-day padding on either side lets overnight shifts (e.g. 4 PM-1 AM)
    attribute their post-midnight checkout correctly."""
    lo = datetime.combine(from_d - timedelta(days=1), datetime.min.time())
    hi = datetime.combine(to_d + timedelta(days=1), datetime.max.time())
    return [
        p for p in punches
        if lo <= datetime.fromisoformat(p["timestamp"]) <= hi
    ]


# -- Backend API ------------------------------------------------------


def login(api_base: str, email: str, password: str) -> str:
    """Log in to the WorkPulse backend and return a JWT access token."""
    try:
        import requests
    except ImportError:
        log.error("requests is not installed. Run: pip install requests")
        sys.exit(2)

    url = f"{api_base.rstrip('/')}/api/v1/auth/login"
    log.info("Logging in as %s ...", email)
    try:
        resp = requests.post(
            url,
            json={"email": email, "password": password},
            timeout=30,
        )
    except Exception as e:
        log.error("Login request failed: %s", e)
        sys.exit(4)

    if not resp.ok:
        log.error("Login failed: HTTP %s %s", resp.status_code, resp.text[:500])
        sys.exit(4)

    raw = resp.json()
    # The backend returns the token at the top level as `access_token`
    # when hit directly (snake_case), but the frontend api client
    # converts to camelCase so the JS side sees `accessToken`. The
    # response may also be wrapped in a `data` envelope depending on
    # endpoint. Accept every shape we've seen.
    def _extract_token(obj) -> Optional[str]:
        if not isinstance(obj, dict):
            return None
        for key in ("access_token", "accessToken", "access"):
            v = obj.get(key)
            if isinstance(v, str) and v:
                return v
        tokens = obj.get("tokens")
        if isinstance(tokens, dict):
            for key in ("access", "access_token", "accessToken"):
                v = tokens.get(key)
                if isinstance(v, str) and v:
                    return v
        return None

    token = _extract_token(raw) or _extract_token(raw.get("data") if isinstance(raw, dict) else None)
    if not token:
        log.error(
            "Login succeeded but no access token in response. Keys: %s",
            list(raw.keys()) if isinstance(raw, dict) else type(raw).__name__,
        )
        sys.exit(4)
    log.info("Login OK")
    return token


def post_backfill(
    api_base: str, token: str,
    from_d: date, to_d: date,
    punches: list[dict], company_id: int,
) -> dict:
    """POST a batch of punches to /attendance/backfill."""
    import requests

    body = {
        "from_date": from_d.isoformat(),
        "to_date": to_d.isoformat(),
        "punches": punches,
        "include_inactive": True,
        "save_raw_punches": False,
    }
    url = f"{api_base.rstrip('/')}/api/v1/attendance/backfill"
    log.info("POST %s (%d punches, %s..%s)", url, len(punches), from_d, to_d)

    resp = requests.post(
        url,
        json=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        timeout=900,
    )
    log.info("HTTP %s", resp.status_code)
    if not resp.ok:
        log.error("Body: %s", resp.text[:2000])
        sys.exit(5)
    return resp.json()


# -- Sync orchestration -----------------------------------------------


def do_sync(
    api: str, email: str, password: str, company_id: int,
    device_ip: str, device_port: int,
    from_d: date, to_d: date,
    dry_run: bool,
) -> None:
    """One sync pass: pull device -> login -> POST by 31-day chunks."""
    punches = pull_all_punches(device_ip, device_port)
    if not punches:
        log.error("No punches on device -- nothing to do")
        return

    lo, hi = detect_range(punches)
    log.info("Device punch range: %s .. %s (%d total)", lo, hi, len(punches))

    in_range = filter_by_range(punches, from_d, to_d)
    log.info("Punches in target range %s..%s: %d", from_d, to_d, len(in_range))

    if dry_run:
        by_user: dict[str, int] = {}
        for p in in_range:
            by_user[p["user_id"]] = by_user.get(p["user_id"], 0) + 1
        log.info("Distinct device users in range: %d", len(by_user))
        log.info("Dry run -- NOT posting to backend")
        return

    token = login(api, email, password)

    # Chunk by 31 days to keep each POST small
    CHUNK_DAYS = 31
    cursor = from_d
    totals: dict[str, int] = {}
    while cursor <= to_d:
        chunk_to = min(cursor + timedelta(days=CHUNK_DAYS - 1), to_d)
        chunk_punches = filter_by_range(in_range, cursor, chunk_to)
        log.info("--- chunk %s..%s : %d punches", cursor, chunk_to, len(chunk_punches))
        resp = post_backfill(api, token, cursor, chunk_to, chunk_punches, company_id)
        data = resp.get("data") or resp
        t = data.get("totals") or {}
        log.info("  -> %s", t)
        for k, v in t.items():
            if isinstance(v, int):
                totals[k] = totals.get(k, 0) + v
        cursor = chunk_to + timedelta(days=1)

    log.info("========== SYNC COMPLETE ==========")
    for k, v in sorted(totals.items()):
        log.info("  %-22s %s", k, v)
    log.info("===================================")


# -- CLI --------------------------------------------------------------


def parse_date(s: str) -> date:
    return datetime.strptime(s, "%Y-%m-%d").date()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="WorkPulse office sync: ZKTeco device -> backend",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Most config comes from environment variables (or a .env file\n"
            "next to this script). Only --from / --to / --dry-run / --loop\n"
            "are typically passed on the command line."
        ),
    )
    p.add_argument("--api", help="Backend base URL (env: WORKPULSE_API)")
    p.add_argument("--email", help="Login email (env: WORKPULSE_EMAIL)")
    p.add_argument("--password", help="Login password (env: WORKPULSE_PASSWORD)")
    p.add_argument("--company-id", type=int, help="Company ID (env: WORKPULSE_COMPANY_ID)")
    p.add_argument("--device-ip", help="Device IP (env: DEVICE_IP)")
    p.add_argument("--device-port", type=int, help="Device port (env: DEVICE_PORT)")
    p.add_argument("--from", dest="from_date",
                   help="YYYY-MM-DD, default: today (or SYNC_WINDOW_DAYS ago)")
    p.add_argument("--to", dest="to_date", help="YYYY-MM-DD, default: today")
    p.add_argument("--dry-run", action="store_true",
                   help="Pull from device + summarize, don't POST")
    p.add_argument("--loop", type=int, metavar="SECONDS",
                   help="Run forever, sleeping SECONDS between runs")
    p.add_argument("--env-file", default=None,
                   help="Path to .env file (default: .env next to script)")
    return p.parse_args()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    args = parse_args()

    # Load .env (script directory by default)
    env_path = args.env_file or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), ".env"
    )
    _load_env_file(env_path)

    # Resolve config (CLI > env > default)
    api = args.api or os.environ.get("WORKPULSE_API") or DEFAULT_API
    email = args.email or os.environ.get("WORKPULSE_EMAIL", "")
    password = args.password or os.environ.get("WORKPULSE_PASSWORD", "")
    company_id = (
        args.company_id
        or int(os.environ.get("WORKPULSE_COMPANY_ID", DEFAULT_COMPANY_ID))
    )
    device_ip = args.device_ip or os.environ.get("DEVICE_IP") or DEFAULT_DEVICE_IP
    device_port = (
        args.device_port
        or int(os.environ.get("DEVICE_PORT", DEFAULT_DEVICE_PORT))
    )
    window_days = int(os.environ.get("SYNC_WINDOW_DAYS", "1"))

    if not args.dry_run and (not email or not password):
        log.error(
            "WORKPULSE_EMAIL / WORKPULSE_PASSWORD must be set (env or .env "
            "file). See .env.example."
        )
        return 1

    def resolve_dates() -> tuple[date, date]:
        today = date.today()
        to_d = parse_date(args.to_date) if args.to_date else today
        if args.from_date:
            from_d = parse_date(args.from_date)
        else:
            from_d = today - timedelta(days=window_days)
        if to_d < from_d:
            log.error("--to (%s) is before --from (%s)", to_d, from_d)
            sys.exit(1)
        return from_d, to_d

    if args.loop:
        log.info("Loop mode: running every %d seconds. Ctrl+C to stop.", args.loop)
        while True:
            try:
                from_d, to_d = resolve_dates()
                do_sync(
                    api, email, password, company_id,
                    device_ip, device_port, from_d, to_d, args.dry_run,
                )
            except SystemExit as e:
                log.error("Sync exited with code %s -- will retry next tick", e.code)
            except Exception as e:
                log.exception("Unexpected error (will retry next tick): %s", e)
            log.info("Sleeping %d seconds...", args.loop)
            time.sleep(args.loop)

    from_d, to_d = resolve_dates()
    do_sync(
        api, email, password, company_id,
        device_ip, device_port, from_d, to_d, args.dry_run,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
