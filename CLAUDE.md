# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-file Python script (`sync.py`) that runs on an office VM with LAN reach to a **ZKTeco K60** biometric device and internet reach to the **WorkPulse HCM** backend at `hcm-api.owesome.work`. It pulls attendance punches over pyzk's TCP protocol, logs in with a service account, and POSTs the punches to `/api/v1/attendance/backfill` in 31-day chunks. There is no framework, no package layout, no test suite, no build step — just `sync.py` + two pip dependencies (`pyzk`, `requests`) + OS-specific wrappers (`run_sync.sh`, `run_sync.cmd`) + a systemd unit + timer.

Everything a scheduler calls is one of those wrappers, not `sync.py` directly.

Both wrappers accept optional positional date args (`run_sync 2026-07-05` or `run_sync 2026-07-01 2026-07-05`), validate against `^YYYY-MM-DD$` (findstr on Windows, bash `[[ =~ ]]` on Linux), and forward as `--from/--to`. No args → nothing forwarded → `sync.py` falls back to the `SYNC_WINDOW_DAYS` env default. Task Scheduler / systemd / cron all pass no args, so the scheduled path is unchanged.

## Common commands

```bash
# One-shot: sync yesterday + today (what the scheduler runs by default)
python sync.py

# Force a specific date range (idempotent — re-running for the same day is safe)
python sync.py --from 2026-04-10 --to 2026-04-10

# Pull from device + summarize, DO NOT post to backend (safe debug tool)
python sync.py --dry-run

# Poll every N seconds forever (alternative to cron/systemd)
python sync.py --loop 60

# Override device for a test
python sync.py --device-ip 192.168.101.248 --dry-run
```

There is no `pytest`, no linter, no formatter configured. If a change needs verification, run `--dry-run` against a reachable device or a `--from/--to` on a known past day and eyeball the summary block.

## Architecture: one pass, top to bottom

Read `sync.py` as five sequential stages — `main()` → `do_sync()` orchestrates:

1. **`_load_env_file(path)`** — homegrown `.env` parser (no `python-dotenv` dependency). Reads `KEY=VALUE`, strips quotes, does **not** override values already in `os.environ`.
2. **Config precedence: CLI flag > env var > `.env` file > hardcoded default.** Every setting resolves through this chain in `main()`. Adding a new setting means threading it through all four layers.
3. **`pull_all_punches(ip, port)`** — pyzk grabs the device's entire attendance memory (~20k rows on a busy office, ~7s). Normalized to `{user_id, timestamp, status}` dicts.
4. **`filter_by_range(punches, from_d, to_d)`** — **widens the window by one day on each side** (`from_d - 1` .. `to_d + 1`). This is intentional and load-bearing: overnight shifts (e.g. 4 PM → 1 AM) have their checkout land on the next calendar day, and the shift-aware calculator on the backend needs both punches to attribute the shift correctly. Don't tighten this without understanding shift attribution.
5. **`login()` → `post_backfill()` in 31-day chunks** — `CHUNK_DAYS = 31` in `do_sync()`. Login accepts every token shape the backend has emitted: top-level `access_token` / `accessToken` / `access`, nested under `tokens.*`, and either shape wrapped in a `data:` envelope. `_extract_token` handles all of them — if the backend adds a new shape, extend that helper, don't work around it at the call site.

The final `SYNC COMPLETE` line only prints if **every** chunk POST returned 2xx. Any network failure in between calls `_network_error_exit()` and `sys.exit()`s before that line is reached, so its presence in the log is a real success signal.

## Loud-fail philosophy (why exit codes are distinct)

A previous version printed "attendance synced" even when uploads silently failed (uncaught `ConnectionError`). Every network failure now maps to a distinct non-zero exit code with a message that names the failure mode. When adding new failure paths, follow the same pattern — don't add generic `except Exception: log.warning(...)` blocks.

| Exit | Meaning |
|---|---|
| 1 | Config error (missing creds, bad `--to`/`--from`) |
| 2 | Missing pip dependency (`pyzk` / `requests`) |
| 3 | Device TCP connect failed |
| 4 | Login HTTP failed or token missing from response |
| 5 | Backfill HTTP non-2xx or non-JSON body |
| 6 | TLS/SSL handshake (usually old OpenSSL — see `_warn_if_openssl_too_old`) |
| 7 | Request timeout |
| 8 | Connection error (DNS, refused, network down) |
| 9 | Other `requests` failure |

`_warn_if_openssl_too_old()` prints a startup banner if the linked OpenSSL is `0.x` / `1.0.0` / `1.0.1` — the backend requires TLS 1.2+. Fix is Python 3.12 from deadsnakes PPA; see README's TLS section.

## Runtime constraints that bite

- **ZKTeco K60 allows exactly ONE active TCP session.** If ZKBioTime is running on the same host, it holds that session and every sync attempt times out. `services.msc` → stop `ZKBioTime*` / `ZKTeco*` before running.
- **Windows Task Scheduler does not inherit the user's PATH.** `run_sync.cmd` therefore prefers `.venv\Scripts\python.exe` by **absolute path** and only falls back to bare `python` (which will silently fail under Task Scheduler with exit 9020 if `python.exe` isn't in the SYSTEM PATH). Keep the absolute-path preference when editing that wrapper.
- **`run_sync.cmd` appends every run to a per-day file `sync-YYYY-MM-DD.log`** with a timestamped header and exit-code footer. The date comes from PowerShell (`Get-Date -Format yyyy-MM-dd`) because `%date%`'s format depends on Regional Settings and is not portable. Files older than `MAX_DAYS=30` are auto-deleted via `forfiles /d -30`. `view_log.cmd` is the convenience reader: `view_log` (today), `view_log yesterday`, `view_log 2026-07-05`, `view_log list`. `run_sync.sh` uses the same header/footer format but writes to a single `sync.log` with no rotation (systemd captures the same stream in journald).
- **VM system clock matters.** Defaults compute `date.today()`; a wrong clock silently syncs the wrong day. `SYNC_WINDOW_DAYS=1` (yesterday + today) is the recommended default so drift and overnight shifts are covered.

## Deploy targets

- **Linux:** `systemd/workpulse-sync.{service,timer}`. Timer fires nightly at 02:30 (catch-all for overnight checkouts) plus every 5 min from 06:00–23:00. `Persistent=true` catches missed runs after reboot. `Type=oneshot` — no restart on failure; the timer's next tick retries.
- **Windows:** Task Scheduler → `run_sync.cmd`. Same 02:30 nightly + 5-min-repeat pattern in the trigger config.
- **Fallback:** `cron` with `run_sync.sh`, or `python sync.py --loop 300` under a supervisor.

## What NOT to add

- Don't introduce a config framework (Pydantic Settings, `python-dotenv`) — the four-layer resolution and homegrown `.env` loader are the point; they keep the deployable surface to `sync.py` + `.env`.
- Don't split `sync.py` into a package. The README and support flow (curl, scp one file, run it) all assume a single file.
- Don't add `requirements-dev.txt` / linting / typechecking config unless asked. `requirements.txt` is intentionally two lines.
