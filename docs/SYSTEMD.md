# systemd deployment & operations

How the three services are managed in production: installed as systemd units,
started on boot, restarted on failure, with Order gated behind its dependencies.

Run everything below **on the VM**.

---

## The dependency design (understand this before deploying)

There are two separate problems, and we solve both:

**Ordering** — Order must start *after* Inventory and Payment. Handled by
`After=inventory.service payment.service` in `order.service`.

**Readiness** — Order must not become *operational* until its dependencies are
actually *listening*. `After=` only guarantees the dependency processes were
launched, not that they're accepting connections. So `order.service` runs
`ExecStartPre=/opt/psenv/scripts/wait-for-deps.sh`, which blocks until both
`/health` endpoints answer.

We also chose `Wants=` (soft) over `Requires=` (hard) for the dependency link.
With `Wants=`, if Payment later dies, Order stays up and returns a clean 502
(handled in code) and recovers on its own when Payment returns. With
`Requires=`, Order would be killed too. Soft is the more resilient, production-style
choice — and it's a deliberate decision you can defend.

Payment calls Order at runtime (the confirm callback) but does NOT depend on
Order to start — that would be a cycle. Payment handles Order being briefly
unavailable in code instead.

---

## Deploy

```bash
# 0. stop any hand-started services so they don't hold the ports
pkill -f 'services/' 2>/dev/null

# 1. create the dedicated service account (no login, no home)
sudo useradd --system --no-create-home --shell /usr/sbin/nologin psenv \
  2>/dev/null || echo "psenv user already exists"

# 2. base tooling (safe to re-run)
sudo apt update && sudo apt install -y python3-venv python3-pip curl rsync

# 3. deploy code to /opt/psenv (native disk). rsync excludes the dev venv/junk.
sudo mkdir -p /opt/psenv
sudo rsync -a --exclude '.venv' --exclude '__pycache__' \
  ~/group-3-devops-networking/psenv/ /opt/psenv/

# 4. build a FRESH venv at the deploy location (never copy a venv)
sudo python3 -m venv /opt/psenv/.venv
sudo /opt/psenv/.venv/bin/pip install -r /opt/psenv/requirements.txt

# 5. make the readiness gate executable, then hand everything to psenv
sudo chmod +x /opt/psenv/scripts/wait-for-deps.sh
sudo chown -R psenv:psenv /opt/psenv

# 6. install the unit files and tell systemd to re-read them
sudo cp ~/group-3-devops-networking/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload

# 7. enable (start on boot) + start now, all three
sudo systemctl enable --now inventory.service payment.service order.service
```

Discovery names must already be in `/etc/hosts` (order/inventory/payment.internal).
If not, see SETUP.md Step 5.

---

## Verify

```bash
# all three should be "active (running)"
systemctl status inventory payment order --no-pager

# confirm they're set to start on boot
systemctl is-enabled inventory payment order      # -> enabled x3

# the pipeline still works, now via systemd-managed services
curl -s -X POST http://127.0.0.1:3001/checkout \
  -H 'Content-Type: application/json' -d '{"items":["BOOK-42"],"amount":3500}'
```

Watch Order's readiness gate do its job at startup:

```bash
journalctl -u order.service | grep wait-for-deps
# -> "...is healthy" for both deps, then "all dependencies ready, starting Order"
```

---

## Operate (standard service commands)

```bash
sudo systemctl start   order      # start
sudo systemctl stop    order      # stop
sudo systemctl restart order      # restart (use this after `git pull` to load new code)
systemctl status       order      # current state
```

Deploying new code becomes: `git pull`, re-run the rsync + pip from Deploy
steps 3-4, then `sudo systemctl restart inventory payment order`. No more
hunting down stale background processes.

---

## Logs (structured JSON via journald)

Because the apps log JSON to stdout, journald captures it automatically.

```bash
journalctl -u order.service                 # all logs for Order
journalctl -u order.service -f              # follow live
journalctl -u order.service --since "5 min ago"
journalctl -u payment.service -o cat | tail -5 | jq .   # pretty-print JSON
```

Trace one order across all three services:

```bash
journalctl -u order -u inventory -u payment -o cat \
  | grep ORD-XXXXXXXX | jq -c '{t:.timestamp, svc:.service, ev:.event}'
```

---

## Reboot-recovery test (the instructor will do this)

```bash
sudo reboot
# reconnect, then:
systemctl status inventory payment order --no-pager
curl -s -X POST http://127.0.0.1:3001/checkout -d '{}'
```

All three should be running with no manual intervention, because they're
`enabled` and Order's gate waits for its dependencies during boot.

---

## Failure demo (the instructor will do this too)

```bash
# stop a dependency
sudo systemctl stop payment

# Order stays UP and returns a clean, traced 502 (graceful degradation)
curl -s -X POST http://127.0.0.1:3001/checkout -d '{}'
journalctl -u order.service -o cat | tail -3 | jq .   # see the downstream_error

# bring it back - no restart of Order needed
sudo systemctl start payment
curl -s -X POST http://127.0.0.1:3001/checkout -d '{}'   # success again
```

Crash recovery (Restart=on-failure):

```bash
# kill the process directly; systemd restarts it within ~2s
sudo systemctl kill -s SIGKILL inventory
sleep 3
systemctl status inventory --no-pager     # active (running) again, see "Restart"
```

---

## Troubleshooting

- `status` shows **failed** → `journalctl -u <svc> -n 50 --no-pager` for the reason.
- Order stuck **activating** → its readiness gate is waiting; a dependency isn't
  healthy. Check `systemctl status inventory payment` and `getent hosts inventory.internal`.
- **Permission denied** in logs → `/opt/psenv` not owned by `psenv`; re-run the
  `chown` from Deploy step 5.
- Edited a unit file → you MUST `sudo systemctl daemon-reload` before restart.
- `ExecStartPre` fails immediately → `wait-for-deps.sh` not executable
  (`chmod +x`) or `curl` not installed.
- Port already in use → a hand-started service is still running: `pkill -f 'services/'`.
