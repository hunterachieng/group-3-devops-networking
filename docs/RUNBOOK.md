# Runbook: running & troubleshooting

How to run the e-commerce pipeline and fix it when it misbehaves. The same
application runs two ways — **Docker Compose** (containers) or **systemd on a
VM** — with identical behavior. Pick the section for your setup.

Service mapping: **A = order, B = inventory, C = payment.** Flow:

```
client → nginx → order → inventory → payment ──confirm callback──→ order → response
```

Only the gateway (nginx) is publicly reachable. Inventory and Payment are
internal. Every service serves JSON, logs JSON to stdout, propagates an
`X-Request-ID` trace, and runs under Gunicorn (`--workers 2 --threads 4`).

---

# Part 1 — Run with Docker Compose

## 1.1 Install Docker

**macOS** — Docker Desktop (includes Engine + Compose v2):

```bash
brew install --cask docker
open /Applications/Docker.app        # launch once to finish setup
```

**Linux (Ubuntu/Debian):**

```bash
sudo apt update
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER && newgrp docker
```

Verify: `docker --version` and `docker compose version` (v2.x).

> **Compose v1 vs v2:** this project uses `docker compose` (space, v2). If a
> machine only has the old `docker-compose` (hyphen, v1), install the plugin
> (`sudo apt install docker-compose-plugin`). On a v1-only machine, every
> `docker compose` below becomes `docker-compose`, and use
> `sh -c "..."` instead of `--` to pass flags to a command in `exec`.

## 1.2 Start the stack

```bash
cd group-3-devops-networking
docker compose up --build -d
docker compose ps             # order, inventory, payment, nginx — all (healthy)
```

First build takes 1–2 min; later builds are cached.

## 1.3 Smoke test

```bash
curl -s http://localhost:8080/health  | python3 -m json.tool          # liveness
curl -s http://localhost:8080/ready   | python3 -m json.tool          # readiness
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1","SKU-2"],"amount":4200}' | python3 -m json.tool
```

Expect `"outcome": "success"` (and `"confirm": "sent"`) on checkout.

## 1.4 Everyday commands

```bash
docker compose logs -f               # stream all logs
docker compose logs order            # one service
docker compose restart order         # restart one
docker compose stop payment          # stop one (others keep running)
docker compose start payment         # bring it back
docker compose up --build -d         # rebuild after code changes
docker compose down                  # stop & remove everything
```

## 1.5 Validate

Full container test suite (9 tests, with expected output) is in
`docs/CONTAINER_VALIDATION.md`. Run it after `up` and capture the output.

---

# Part 2 — Run on a VM with systemd

## 2.1 First-time setup

Per-machine environment setup (VM, Python, discovery names) is in
`docs/SETUP.md`. One-command deploy:

```bash
git clone https://github.com/hunterachieng/group-3-devops-networking.git ~/group-3-devops-networking
cd ~/group-3-devops-networking
bash scripts/install.sh              # idempotent; re-run to redeploy
```

## 2.2 Operate

```bash
sudo systemctl start   inventory payment order
sudo systemctl stop    order payment inventory
sudo systemctl restart inventory payment order   # after a git pull + redeploy
systemctl status inventory payment order --no-pager
```

Public port here is **80** (not 8080):

```bash
curl -s http://localhost/health
curl -s -X POST http://localhost/checkout -d '{"items":["SKU-1"],"amount":100}'
```

## 2.3 Validate

```bash
bash scripts/verify.sh               # discovery, bindings, health, readiness,
                                     # full flow, and B/C sealed from outside
```

Deep dives: `docs/SYSTEMD.md` (lifecycle), `docs/NGINX.md` (proxy),
`docs/NETWORK-SECURITY.md` (protection), `docs/PROOF.md` (evidence).

---

# Part 3 — Key behaviors (both runtimes)

## 3.1 Readiness vs liveness

| Endpoint | Means | Fails when |
|----------|-------|------------|
| `GET /health` | process is alive, can serve HTTP | the process crashed/hung |
| `GET /ready`  | alive AND required downstream responds | a dependency is down |

Readiness is **transitive**: Order's `/ready` checks Inventory's `/ready`,
Inventory's `/ready` checks Payment's `/health`, and Payment's `/ready` is
always ready (its callback to Order is best-effort). So if Payment dies,
Inventory and Order both report not-ready, and `GET /ready` at the gateway
reflects the whole pipeline. Response shape:

```
200  {"status": "ready",     "dependencies": {"inventory": true}}
503  {"status": "not_ready", "dependencies": {"inventory": false}}
```

`/health` stays 200 throughout an outage (the process is alive); only `/ready`
flips to 503. Compose healthchecks use `/health` (not `/ready`) for the
`depends_on` gate — intentionally, so one service going down doesn't cascade
into restarts; `/ready` is exposed for a load balancer/orchestrator to consume.

## 3.2 Callback coupling (no deadlock)

Payment calls Order's `/confirm` after charging — the only inter-service cycle.
It cannot deadlock because:

1. **Gunicorn has 8 concurrent slots per service** (`--workers 2 --threads 4`).
   The thread serving `/checkout` blocks on the downstream call, but other
   threads are free to accept the inbound `/confirm`. A single-threaded server
   would deadlock; the thread pool prevents it.
2. **The callback is best-effort.** If Order is unreachable, Payment logs a
   warning (`confirm_error`) and still returns 200 — the charge isn't rolled
   back, and `/charge` never fails because of Order.
3. **Startup graph is acyclic.** `payment` has no `depends_on`; it starts first.
   It only calls Order at *runtime*, never at startup. So there's no circular
   dependency.

Under a burst beyond 8 concurrent slots, some requests may return 502 (the
5s `DOWNSTREAM_TIMEOUT` expiring) — that's capacity limiting, not a deadlock.
The proof is every request *finishes* (200 or 502) rather than hanging.

## 3.3 Dependency recovery

When a downstream dies and restarts:

1. **During the outage** the upstream returns a clean 502 with a descriptive
   error — it doesn't crash. `/health` keeps passing; `/ready` returns 503.
2. **After restart** (`restart: unless-stopped` in Compose, `Restart=on-failure`
   in systemd) the next request succeeds automatically — no manual restart,
   cache flush, or reconnect.
3. **No state to reconcile** — services are stateless; each HTTP request is
   independent.

Exact verification commands: `docs/CONTAINER_VALIDATION.md` Test 9 (containers)
and `docs/PROOF.md` §4 (VM).

---

# Part 4 — Troubleshooting

## 4.1 Docker Compose

| Symptom | Fix |
|---------|-----|
| `docker: command not found` | Docker isn't installed — see §1.1 |
| `docker compose` → "unknown command" | You have v1 only; use `docker-compose` (hyphen) or install `docker-compose-plugin` |
| `unknown shorthand flag: 'f'` in `exec` | Flags reached Docker, not curl. Use `docker-compose exec order sh -c "curl -fsS http://inventory:3002/health"` |
| `No such container: order` | Use `docker compose exec order ...` (resolves the name), or the stack isn't up — `docker compose ps` |
| `permission denied` (Linux) | `sudo usermod -aG docker $USER && newgrp docker` |
| `port 8080 already in use` | Find it: `sudo lsof -i :8080`; or change the host port in `docker-compose.yml` (`"9090:80"`) |
| Container shows `unhealthy` | `docker compose logs <service>` — usually an import error or a dependency not ready |
| Build fails on ARM Mac | base images are multi-arch; if needed `export DOCKER_DEFAULT_PLATFORM=linux/arm64` before build |
| Another project owns port 80/8080 | Stop it, or run this on a dedicated VM; only nginx should hold the public port |

## 4.2 VM / systemd

| Symptom | Fix |
|---------|-----|
| Service `failed` | `journalctl -u <svc> -n 50 --no-pager`; common: code not deployed to `/opt/psenv`, wrong ownership, missing venv |
| Order stuck `activating` | Its readiness gate is waiting; a dependency isn't healthy. Check `systemctl status inventory payment` |
| nginx `502 Bad Gateway` | nginx up but Order down — `systemctl status order` |
| nginx serves the stock welcome page | default site still enabled — `sudo rm /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl reload nginx` |
| `host not found in upstream "order.internal"` | discovery names missing — re-add the `/etc/hosts` entries (SETUP.md), they resolve at nginx load |
| Public IP can't reach :80 | firewall denying 80 (`sudo ufw status`) or nginx down |
| An internal port reachable from outside | a service is binding `0.0.0.0` — set `BIND_HOST=127.0.0.1`, `daemon-reload`, restart |

## 4.3 Application / behavior (either runtime)

| Symptom | Fix |
|---------|-----|
| Checkout returns 502 | A downstream is down. Containers: `docker compose ps`. VM: `systemctl status`. Logs show `downstream_error` with the unreachable target |
| `/ready` is 503 but `/health` is 200 | Working as designed — a dependency is unavailable; the process is alive but not ready |
| Trace id missing in some logs | Confirm the request carried/received `X-Request-ID`; nginx originates one if absent. Grep all services for the id |
| Unknown endpoint returns HTML 404 (not JSON) | The request didn't reach Order — it's an nginx/route 404, not the app's JSON 404 |
| Missing logs | Logs go to stdout, not files. Containers: `docker compose logs <svc>`. VM: `journalctl -u <svc>` |
| `jq: command not found` | Logs are already JSON; drop the `| jq` or `sudo apt install jq` |

## 4.4 Git / workflow

| Symptom | Fix |
|---------|-----|
| `Permission denied (publickey)` inside the VM | You're in the virtiofs share (`/Users/...`) which uses the Mac's SSH remote. `cd ~` first to use the native HTTPS clone; check with `pwd` |
| Changes pushed but VM unchanged | A running process keeps old code until restarted. Containers: `docker compose up --build -d`. VM: redeploy + `systemctl restart` |
| Teammate's clone won't pull after a history rewrite | Re-clone, or `git fetch && git reset --hard origin/main` (discards local changes) |

---

For architecture, design rationale, and the required README sections, see
`README.md`. For container validation evidence, `docs/CONTAINER_VALIDATION.md`.