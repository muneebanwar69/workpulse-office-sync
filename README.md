# WorkPulse Office Sync

One-file Python script that pulls attendance punches from a **ZKTeco K60**
biometric device on your office LAN and pushes them to the **WorkPulse HCM**
production backend. Keeps every employee's timesheet up-to-date automatically,
24/7, without ZKBioTime or any other middleware.

```
ZKTeco K60 (192.168.101.247:4370)
      │  LAN, pyzk TCP protocol
      ▼
Office VM (this repo)        ← cron / systemd / Task Scheduler
      │  HTTPS, JWT
      ▼
ikonic-hcm.demosites.cc      ← /api/v1/attendance/backfill
      │
      ▼
Production Postgres          ← shift-aware attendance_records rows
```

Zero dependency on the backend repo. Only two pip packages. Designed to
run on a tiny Linux or Windows VM that has LAN reach to the device and
internet reach to the backend.

---

## What it does on each run

1. Opens a TCP connection to the ZKTeco K60 (port 4370)
2. Pulls every punch the device has in its memory (typically ~20k rows, ~7 s)
3. Filters them to the target date range (default: yesterday + today, to
   catch late overnight 4 PM–1 AM shifts whose checkout lands after midnight)
4. Logs in to WorkPulse with a service account → gets a fresh JWT
5. POSTs the punches to `POST /api/v1/attendance/backfill` in 31-day chunks
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
nano .env      # fill in WORKPULSE_EMAIL and WORKPULSE_PASSWORD
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
Fill in `WORKPULSE_EMAIL` and `WORKPULSE_PASSWORD`, save, close.

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

`C:\workpulse-office-sync\sync.log` (the `run_sync.cmd` wrapper appends
stdout+stderr there when run via cron/task scheduler). Or check Task
Scheduler → Task history for the exit codes.

---

## Configuration reference

All settings can be set via environment variables, a `.env` file, or CLI
flags. Precedence: **CLI flag > env var > .env file > hardcoded default**.

| Setting | Env var | CLI flag | Default |
|---|---|---|---|
| Backend URL | `WORKPULSE_API` | `--api` | `https://ikonic-hcm.demosites.cc` |
| Login email | `WORKPULSE_EMAIL` | `--email` | *required* |
| Login password | `WORKPULSE_PASSWORD` | `--password` | *required* |
| Company ID | `WORKPULSE_COMPANY_ID` | `--company-id` | `1` |
| Device IP | `DEVICE_IP` | `--device-ip` | `192.168.101.247` |
| Device port | `DEVICE_PORT` | `--device-port` | `4370` |
| Sync window (days back) | `SYNC_WINDOW_DAYS` | — | `1` |
| From date | — | `--from YYYY-MM-DD` | today − `SYNC_WINDOW_DAYS` |
| To date | — | `--to YYYY-MM-DD` | today |
| Dry run | — | `--dry-run` | off |
| Continuous loop | — | `--loop SECONDS` | off |

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

---

## Recommended setup: dedicated service account

Don't use your personal CEO login as the sync credential. In WorkPulse:

1. Log in as CEO → **Setup → User Accounts → New**
2. Create employee `Sync Bot` with email `sync-bot@ikonicsolution.com`
3. Assign role: `it_admin` **or** a custom role with exactly
   `devices:manage` + `attendance:create` + `employee:view_all` permissions
4. Set a strong random password and paste into `.env`

Benefits:
- Rotating this password won't log you out of the real CEO session
- Audit trail shows `Sync Bot` as the source, not a human
- Can be revoked instantly if a VM is ever compromised

---

## Troubleshooting

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

### `HTTP 401 Unauthorized` on backfill

The login worked but the returned token doesn't have the right
permissions. Either:
- Your service account lacks `devices:manage` / `attendance:create`, OR
- The JWT expired between login and POST (shouldn't happen — tokens are
  valid for ~3 months)

Fix the role in WorkPulse → **Setup → Roles & Permissions** and re-run.

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

The `.cmd` wrapper exited with an error. Check `sync.log` next to the
script for the Python traceback.

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
├── run_sync.cmd                 ← Windows wrapper (activates venv)
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
