# WorkPulse Office Sync

One-file Python script that pulls attendance punches from a **ZKTeco K60**
biometric device on your office LAN and pushes them to the **WorkPulse HCM**
production backend. Keeps every employee's timesheet up-to-date automatically,
24/7, without ZKBioTime or any other middleware.

```
ZKTeco K60 (192.168.101.247:4370)
      │  LAN, pyzk TCP protocol
      ▼
Office VM (this repo)          ← cron / systemd / Task Scheduler
      │  1) HTTPS  login (email + password)
      ▼
api.owesome.work              ← Owesome IdP: verifies creds, returns access token
      │  2) HTTPS  token + X-Workspace-Id
      ▼
hr-api.owesome.work           ← /api/v1/attendance/backfill
      │
      ▼
Production Postgres            ← shift-aware attendance_records rows
```

> **Auth changed with the Owesome SSO cutover.** Credentials are now verified by
> the **Owesome IdP** (`api.owesome.work`), not the HR backend. The script logs
> in there, then sends the returned token **plus `X-Workspace-Id`** to the HR
> sync API (`hr-api.owesome.work`), which resolves the tenant, role and
> permissions from the workspace.

Zero dependency on the backend repo. Only two pip packages. Designed to
run on a tiny Linux or Windows VM that has LAN reach to the device and
internet reach to the backend.

---

## What it does on each run

1. Opens a TCP connection to the ZKTeco K60 (port 4370)
2. Pulls every punch the device has in its memory (typically ~20k rows, ~7 s)
3. Filters them to the target date range (default: yesterday + today, to
   catch late overnight 4 PM–1 AM shifts whose checkout lands after midnight)
4. Logs in to the **Owesome IdP** with a service account → gets a fresh access token
5. POSTs the punches to `hr-api …/api/v1/attendance/backfill` (with the token +
   `X-Workspace-Id`) in 31-day chunks
6. Backend runs them through the **shift-aware attendance calculator**
   (handles late / early departure / half-day / overnight / holiday /
   weekend / leave / WFH precedence), then UPSERTs `attendance_records`
7. Prints a summary: `records_created`, `records_updated`, `late`,
   `absent`, `early_departures`, `unmapped_device_users`, etc.

Idempotent: running it twice for the same day is safe.

---

## Quick start (Linux — recommended)

On a fresh Ubuntu 22.04 VM that can ping `192.168.101.247`:

```bash
# 1. Install Python + git
sudo apt update
sudo apt install -y python3 python3-pip python3-venv git

# 2. Clone this repo
cd /opt
sudo git clone https://github.com/muneebanwar69/workpulse-office-sync.git
sudo chown -R $USER:$USER workpulse-office-sync
cd workpulse-office-sync

# 3. Virtualenv + dependencies
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 4. Credentials
cp .env.example .env
nano .env      # fill in WORKPULSE_EMAIL, WORKPULSE_PASSWORD, WORKPULSE_WORKSPACE_ID
chmod 600 .env

# 5. Smoke-test the device connection (NO backend call)
python sync.py --dry-run
# Expected: "Pulled N punches from device"

# 6. Real run (syncs yesterday + today)
python sync.py

# 7. Schedule it — pick ONE of the two options below
```

### Option A — systemd timer (robust, logged, survives reboots)

```bash
sudo cp systemd/workpulse-sync.service /etc/systemd/system/
sudo cp systemd/workpulse-sync.timer   /etc/systemd/system/
# Edit the unit file to match your user/path if you didn't clone to
# /home/workpulse/workpulse-office-sync:
sudo nano /etc/systemd/system/workpulse-sync.service
sudo systemctl daemon-reload
sudo systemctl enable --now workpulse-sync.timer

# Check the timer is armed:
systemctl list-timers | grep workpulse
# View logs:
journalctl -u workpulse-sync.service -f
```

The timer runs:
- **Nightly at 02:30** — catches late overnight checkouts
- **Every 5 minutes from 06:00 to 23:00** — near-real-time dashboards
- **Immediately on boot** if the scheduled time was missed (`Persistent=true`)

### Option B — cron (simpler)

```bash
crontab -e
# Append:
30 2   * * * /opt/workpulse-office-sync/run_sync.sh >> /opt/workpulse-office-sync/sync.log 2>&1
*/5 6-23 * * * /opt/workpulse-office-sync/run_sync.sh >> /opt/workpulse-office-sync/sync.log 2>&1
```

---

## Quick start (Windows — if your office VM runs Windows Server)

The existing ZKBioTime install is almost always Windows, so this is likely
your path.

### 1. Install Python 3.11

Download from <https://www.python.org/downloads/>. During install, tick
**"Add Python to PATH"**.

### 2. Install git (or just download the ZIP)

<https://git-scm.com/download/win>

### 3. Clone the repo

```cmd
cd C:\
git clone https://github.com/muneebanwar69/workpulse-office-sync.git
cd workpulse-office-sync
```

### 4. Virtualenv + dependencies

```cmd
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

### 5. Credentials

```cmd
copy .env.example .env
notepad .env
```
Fill in `WORKPULSE_EMAIL`, `WORKPULSE_PASSWORD` and `WORKPULSE_WORKSPACE_ID`,
save, close.

Lock the file: right-click `.env` → Properties → Security → remove Users,
keep only SYSTEM + your own account.

### 6. Smoke-test

```cmd
python sync.py --dry-run
```
You should see `Pulled N punches from device`. If you get
`Failed to connect to device`, the ZKBioTime service is still running and
holding the device's single TCP session. Stop it in `services.msc`
(the name usually contains "BioTime" or "ZKTeco"), then retry.

### 7. Real run

```cmd
python sync.py
```
Expected tail:
```
=========== SYNC COMPLETE ===========
  absent                 12
  days_processed         2
  days_with_errors       0
  early_departures       4
  late                   7
  records_created        0
  records_updated        287
======================================
```

### 8. Schedule with Task Scheduler

Open **Task Scheduler → Create Task**:

- **General** tab:
  - Name: `WorkPulse Sync`
  - Security options → ✓ "Run whether user is logged on or not"
  - ✓ "Run with highest privileges"
  - Configure for: `Windows Server 2019` (or whatever you have)
- **Triggers** tab → New:
  - Begin the task: On a schedule
  - Daily, at 02:30 AM, recur every 1 day
  - ✓ **Repeat task every: 5 minutes**, for a duration of: 1 day
  - ✓ Enabled
- **Actions** tab → New:
  - Action: Start a program
  - Program/script: `C:\workpulse-office-sync\run_sync.cmd`
  - Start in: `C:\workpulse-office-sync`
- **Conditions** tab:
  - Uncheck "Start the task only if the computer is on AC power"
- **Settings** tab:
  - ✓ "Run task as soon as possible after a scheduled start is missed"
  - ✓ "If the task fails, restart every 5 minutes, up to 3 times"
  - "Stop the task if it runs longer than: 30 minutes"

Click OK, enter the user password when prompted.

### 9. View logs

The Windows wrapper writes **one log file per day**, named
`sync-YYYY-MM-DD.log` (e.g. `sync-2026-07-09.log`). Each run appends a
timestamped header, its stdout+stderr, and a footer with the exit code,
so a single day's file contains every run for that day. Files older
than 30 days are auto-deleted on the next run.

Use the bundled `view_log.cmd` helper — no arguments needed for the
common case:

```cmd
rem Show today's log
view_log

rem Show yesterday's log
view_log yesterday

rem Show a specific date
view_log 2026-07-05

rem List all available log files (newest first)
view_log list
```

Or use the raw file directly:

```cmd
type sync-2026-07-09.log
dir /b /o-n sync-*.log
```

> **Note:** `type sync.log` (no date) will fail with "The system cannot
> find the file specified" — the wrapper no longer writes to a plain
> `sync.log`. Use `view_log` or `sync-YYYY-MM-DD.log` instead.

For exit codes at a glance, check Task Scheduler → Task history.

---

## Configuration reference

All settings can be set via environment variables, a `.env` file, or CLI
flags. Precedence: **CLI flag > env var > .env file > hardcoded default**.

| Setting | Env var | CLI flag | Default |
|---|---|---|---|
| Sync API (HR backend) | `WORKPULSE_API` | `--api` | `https://hr-api.owesome.work` |
| Owesome IdP (login) | `OWESOME_IDP_URL` | — | `https://api.owesome.work` |
| Login email | `WORKPULSE_EMAIL` | `--email` | *required* |
| Login password | `WORKPULSE_PASSWORD` | `--password` | *required* |
| Workspace UUID (`X-Workspace-Id`) | `WORKPULSE_WORKSPACE_ID` | — | *required* |
| Device IP | `DEVICE_IP` | `--device-ip` | `192.168.101.247` |
| Device port | `DEVICE_PORT` | `--device-port` | `4370` |
| Sync window (days back) | `SYNC_WINDOW_DAYS` | — | `1` |
| From date | — | `--from YYYY-MM-DD` | today − `SYNC_WINDOW_DAYS` |
| To date | — | `--to YYYY-MM-DD` | today |
| Dry run | — | `--dry-run` | off |
| Continuous loop | — | `--loop SECONDS` | off |

> `WORKPULSE_WORKSPACE_ID` is the Owesome **workspace UUID** for this company
> (from the workspace URL or an admin). The HR API needs it to resolve which
> tenant the punches belong to. The old `WORKPULSE_COMPANY_ID` is gone — the
> company is derived from the workspace now.

---

## Common commands

```bash
# Sync yesterday + today (what the scheduler runs)
python sync.py

# Force a specific date
python sync.py --from 2026-04-10 --to 2026-04-10

# Bulk backfill a month (one-off catch-up)
python sync.py --from 2025-11-14 --to 2026-04-13

# Pull from device but DON'T post — useful for debugging
python sync.py --dry-run

# Run forever, polling every 60 seconds (alternative to cron/systemd)
python sync.py --loop 60

# Override device IP for a test
python sync.py --device-ip 192.168.101.248 --dry-run
```

### Wrapper shortcut: `run_sync` with date args

Both wrappers (`run_sync.cmd` on Windows, `run_sync.sh` on Linux) accept
up to two positional dates and translate them into `--from`/`--to` for
`sync.py`. Same syntax on both platforms.

```cmd
rem Windows
run_sync                          rem default: SYNC_WINDOW_DAYS from .env
run_sync 2026-07-05               rem one day
run_sync 2026-07-01 2026-07-05    rem inclusive range
```

```bash
# Linux
./run_sync.sh                          # default: SYNC_WINDOW_DAYS from .env
./run_sync.sh 2026-07-05               # one day
./run_sync.sh 2026-07-01 2026-07-05    # inclusive range
```

Dates must be `YYYY-MM-DD`; a malformed date exits `1` with a usage
line before any work happens. Task Scheduler / systemd / cron all
invoke the wrappers with no args, so the scheduled path is unchanged
— this is only for manual one-off backfills.

---

## Recommended setup: dedicated service account

Don't use your personal CEO login as the sync credential. Post-SSO the service
account must be a proper **Owesome identity** with HR access:

1. It exists as an **Owesome account** (email + password that works at
   `api.owesome.work`), e.g. `sync-bot@ikonicsolution.com`.
2. It is a **member of the workspace** in `WORKPULSE_WORKSPACE_ID`, and that
   workspace has an **active HR subscription**.
3. In HR it holds a role granting **`devices:manage`** or **`attendance:create`**
   (e.g. `super_admin` / `hr_admin`, or a custom role with exactly those
   permissions). HR owns its roles, so once assigned it stays put across logins.
4. Set a strong password and paste it into `.env`.

Benefits:
- Rotating this password won't log you out of the real CEO session
- Audit trail shows `Sync Bot` as the source, not a human
- Can be revoked instantly if a VM is ever compromised

---

## Troubleshooting

### `SSL: SSLV3_ALERT_HANDSHAKE_FAILURE` / `ssl.SSLError` on the VPS

A TLS handshake with the host was rejected. **First check which cause it is** —
what does Python's own OpenSSL report?

```bash
python3 -c "import ssl; print(ssl.OPENSSL_VERSION)"
```

**Case A — OpenSSL is old (`OpenSSL 0.x` or `1.0.x`).** It genuinely can't do
TLS 1.2+. Install a modern Python 3.12 on Ubuntu:

```bash
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python3.12 python3.12-venv python3.12-distutils
curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12
python3.12 -m pip install -r requirements.txt
python3.12 sync.py
# then point cron/systemd at `python3.12` (run `which python3.12` for the path)
```

**Case B — OpenSSL is already modern (`1.1.1` / `3.x`) but the handshake still
fails.** This is *not* an old-Python problem — it's a host/edge TLS mismatch (the
new `hr-api.owesome.work` is fronted by Cloudflare with a stricter TLS profile
than the old `hcm-api` had). Diagnose from the VPS:

```bash
# raw handshake — does OpenSSL itself fail, or just Python/requests?
openssl s_client -connect hr-api.owesome.work:443 -servername hr-api.owesome.work </dev/null | head -20

# does a plain HTTPS GET work at all?
curl -sS -o /dev/null -w "%{http_code}\n" https://hr-api.owesome.work/
```

If `openssl s_client` / `curl` also fail, it's the edge — fix it in **Cloudflare**
(SSL/TLS → Edge Certificates → set **Minimum TLS Version** to 1.2 and confirm the
zone's cipher profile is compatible with your clients). If they succeed but
Python fails, a restrictive system `openssl.cnf` (SECLEVEL / disabled groups) on
that box is the culprit.

> The `login` step exits with code `6` on any SSL error rather than pretending
> the sync worked, and prints Python's OpenSSL version to help you tell A from B.

### `Failed to connect to device: [Errno timeout]`

The ZKTeco K60 allows only ONE active TCP session. Something else is
holding it — usually ZKBioTime running on the same machine. Stop its
service and retry.

```cmd
rem Windows
sc stop ZKBioTimeNet
sc stop ZKBioTime
```
```bash
# Linux — if the old ZK daemon is installed
sudo systemctl stop zkbiotime 2>/dev/null
```

### `HTTP 401 / 403 / 400` on backfill (after a successful login)

The IdP login worked but the HR sync API rejected the token. Common causes:
- **400 `no workspace` / missing context** — `WORKPULSE_WORKSPACE_ID` is unset or
  wrong. It must be the Owesome **workspace UUID** for this company.
- **403 `not subscribed` / `no HR access`** — that workspace has no active HR
  entitlement, or the service account isn't a member of it.
- **403 permission denied** — the account's HR role lacks `devices:manage` /
  `attendance:create`. Assign it a role that has them (e.g. `hr_admin`).
- **401 token invalid/expired** — re-run (a fresh token is fetched each run).

Fix the workspace membership / role in HR and re-run.

### `unmapped_device_users: ["999", "1001"]` in the summary

Those device user IDs don't have a matching `employee_id` in the
WorkPulse database. The device had their fingerprints enrolled but
they were never added as employees (or were deleted). Options:
- Ignore if they've left the company
- In WorkPulse → **HR → Employees → New**, create them with the
  matching `employee_id` (the numeric code from the device)
- Next sync will pick them up automatically

### The sync runs but the dashboard still shows old data

Two common causes:
1. **Frontend cache** — hard-refresh with Ctrl+F5
2. **Wrong date** — check that the VM's system clock is correct
   (the script uses `date.today()`). Run `date` (Linux) or `time /t` (Win)

### Task Scheduler shows "Last Run Result: 0x1"

The `.cmd` wrapper exited with an error. Check today's per-day log file
next to the script for the Python traceback — `view_log` prints today's
in one command, or grab it directly:

```cmd
type sync-YYYY-MM-DD.log
```

### Want to disable the sync temporarily

```bash
sudo systemctl stop workpulse-sync.timer       # Linux
```
Or in Task Scheduler, right-click the task → **Disable**.

---

## Updating

```bash
cd /opt/workpulse-office-sync   # or wherever you cloned
git pull
source .venv/bin/activate
pip install -r requirements.txt --upgrade
```

No restart needed — the next scheduled run picks up the new `sync.py`.

---

## Uninstalling the old ZKTeco software (after you've verified this works for 2-3 days)

Windows:
```
services.msc → Stop all services named "ZKBioTime*" / "ZKTeco*"
Control Panel → Programs → Uninstall ZKBioTime
```
That frees the device's TCP session completely and prevents conflicts.

---

## Security notes

- **`.env` is in `.gitignore`** — it will never be committed
- **JWT is fetched fresh on every run** — no long-lived secrets in the script
- **Credentials live only on the office VM** — not on the VPS backend, not in the cloud
- **The `backfill` endpoint requires `devices:manage` permission** — a
  stolen read-only token can't abuse it
- **Recommended:** dedicated service account, not your CEO login

---

## File layout

```
workpulse-office-sync/
├── README.md                    ← this file
├── sync.py                      ← the one-file script
├── requirements.txt             ← pyzk + requests
├── .env.example                 ← copy to .env and fill in secrets
├── .gitignore                   ← keeps .env / logs out of git
├── run_sync.sh                  ← Linux wrapper (activates venv)
├── run_sync.cmd                 ← Windows wrapper (per-day sync-YYYY-MM-DD.log)
├── view_log.cmd                 ← Windows log reader (today / yesterday / date / list)
└── systemd/
    ├── workpulse-sync.service   ← systemd unit (Linux)
    └── workpulse-sync.timer     ← systemd timer (Linux)
```

Only `sync.py` + `.env` + `requirements.txt` are strictly required — the
wrappers and unit files are convenience. If you want the absolute minimum,
just download `sync.py`, create a `.env`, `pip install pyzk requests`,
and run `python sync.py`.

---

## Related

- Backend: [IKONIC-DEV/Ikonic-hcm](https://github.com/IKONIC-DEV/Ikonic-hcm)
  — the FastAPI backend this script talks to
- Frontend: [muneebanwar69/workpulse-hcm-frontend](https://github.com/muneebanwar69/workpulse-hcm-frontend)
  — the Next.js dashboard where the synced data shows up

The backend's shift-aware calculator lives in
[`app/services/attendance_calculator.py`](https://github.com/IKONIC-DEV/Ikonic-hcm/blob/main/app/services/attendance_calculator.py)
— that's what decides late / early / overtime / status for each punch this
script sends.
