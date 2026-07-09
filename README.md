# group-3-devops-networking

A small production-style service environment: three internal HTTP services that
form an e-commerce checkout pipeline, fronted by an Nginx reverse proxy, managed
by systemd, secured at the network layer, and observable through structured logs
and request tracing.

---

## Project overview

The system models a checkout flow across three independent services:

- **Order** receives the customer's checkout, starts the pipeline, and is
  notified when the order is confirmed.
- **Inventory** reserves stock and hands off to Payment.
- **Payment** charges the customer and confirms back to Order.

Only Order is publicly reachable, and only through Nginx. Inventory and Payment
are internal infrastructure: they bind to loopback and are unreachable from
outside the VM. Every service exposes a health endpoint, emits structured JSON
logs, propagates a request trace across the whole pipeline, starts on boot,
restarts on failure, and recovers automatically after a reboot. Services are
served by Gunicorn (a production WSGI server), not the Flask dev server.

---

## Architecture

| Role      | Service identity   | Discovery name       | Port | Public? | Endpoint        |
|-----------|--------------------|----------------------|------|---------|-----------------|
| Order     | order-service      | order.internal       | 3001 | via Nginx | POST /checkout |
| Inventory | inventory-service  | inventory.internal   | 3002 | no      | POST /reserve   |
| Payment   | payment-service    | payment.internal     | 3003 | no      | POST /charge    |

Every service also exposes `GET /health` (liveness) and `GET /ready` (readiness:
reflects whether required downstream dependencies are reachable). Payment confirms
back to Order at
`POST /confirm`.

```
Client
  |  POST /checkout                         (public, port 80)
  v
+-----------+
|   Nginx   |  :80   (the ONLY publicly-bound process)
+-----------+
  |  proxy_pass -> order.internal:3001  (originates X-Request-ID trace)
  v
+-----------+   reserve    +-------------+   charge    +-----------+
|   Order   | -----------> |  Inventory  | ----------> |  Payment  |
|   :3001   |              |    :3002    |             |   :3003   |
+-----------+              +-------------+             +-----------+
  ^                                                          |
  |        POST /confirm   (payment confirmed, order done)   |
  +----------------------------------------------------------+

All three services bind 127.0.0.1 only. Inventory & Payment are never public.
```

How components interact: a request enters at Nginx on port 80, which forwards
only to Order. Order calls Inventory (`/reserve`), Inventory calls Payment
(`/charge`), and Payment calls back to Order (`/confirm`) to complete the order.
The synchronous responses also unwind back up the chain. Services find each
other by name (`*.internal`), never by hardcoded IP.

---

## Repository layout

```
psenv/                     application (deployed to /opt/psenv)
  services/
    common/logging_setup.py  shared JSON logger + trace helpers
    order/ inventory/ payment/  the three services
  scripts/wait-for-deps.sh   readiness gate used by order.service
  requirements.txt
systemd/                   order/inventory/payment .service units
nginx/reverse-proxy.conf   reverse proxy config
scripts/
  setup-firewall.sh        ufw defense-in-depth firewall
  verify.sh                one-command health + security proof
docs/                      detailed runbooks (see Documentation index below)
```

---

## Installation

Prerequisites: an Ubuntu VM. First-time/teammate environment setup is in
`docs/SETUP.md`.

**One command (recommended):**

```bash
git clone https://github.com/hunterachieng/group-3-devops-networking.git ~/group-3-devops-networking
cd ~/group-3-devops-networking
bash scripts/install.sh         # idempotent; re-run to redeploy new code
```

`install.sh` performs every step below, is safe to re-run, and ends by running
the verification. Skip the firewall with `SKIP_FIREWALL=1 bash scripts/install.sh`.

<details>
<summary><strong>What install.sh does (the manual equivalent)</strong></summary>

```bash
# 1. base tooling
sudo apt update && sudo apt install -y git python3-venv python3-pip curl rsync nginx ufw

# 2. clone (use HTTPS on the VM; the VM only pulls)
git clone https://github.com/hunterachieng/group-3-devops-networking.git ~/group-3-devops-networking
cd ~/group-3-devops-networking

# 3. service discovery names
echo '127.0.0.1 order.internal
127.0.0.1 inventory.internal
127.0.0.1 payment.internal' | sudo tee -a /etc/hosts

# 4. dedicated service account + deploy code to native disk
sudo useradd --system --no-create-home --shell /usr/sbin/nologin psenv 2>/dev/null || true
sudo mkdir -p /opt/psenv
sudo rsync -a --exclude '.venv' --exclude '__pycache__' psenv/ /opt/psenv/
sudo python3 -m venv /opt/psenv/.venv
sudo /opt/psenv/.venv/bin/pip install -r /opt/psenv/requirements.txt
sudo chmod +x /opt/psenv/scripts/wait-for-deps.sh
sudo chown -R psenv:psenv /opt/psenv

# 5. systemd units (start on boot, restart on failure, ordered)
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now inventory.service payment.service order.service

# 6. reverse proxy
sudo cp nginx/reverse-proxy.conf /etc/nginx/sites-available/ecommerce.conf
sudo ln -sf /etc/nginx/sites-available/ecommerce.conf /etc/nginx/sites-enabled/ecommerce.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx && sudo systemctl enable nginx

# 7. firewall + verify everything
sudo bash scripts/setup-firewall.sh
bash scripts/verify.sh
```

Detailed, explained versions of each block: `docs/SYSTEMD.md`, `docs/NGINX.md`,
`docs/NETWORK-SECURITY.md`.

</details>

---

## Operation

```bash
# start / stop / restart all three services
sudo systemctl start   inventory payment order
sudo systemctl stop    order payment inventory
sudo systemctl restart inventory payment order   # use after `git pull` + redeploy

# status and boot-enablement
systemctl status inventory payment order --no-pager
systemctl is-enabled inventory payment order      # -> enabled

# nginx
sudo nginx -t && sudo systemctl reload nginx
```

Deploying new code: `git pull` (from `~`, see Troubleshooting), re-run install
steps 4-5's rsync + restart.

---

## Validation

```bash
bash scripts/verify.sh
```

Prints PASS/FAIL for: discovery names, loopback-only bindings, Nginx public,
health endpoints, the full checkout pipeline through port 80, and proof that
Inventory/Payment are sealed on the public IP. `ALL CRITICAL CHECKS PASSED`
means the system meets every core requirement. A quick manual check:

```bash
curl -s http://localhost/health
curl -s -X POST http://localhost/checkout -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}'
```

Reboot recovery: `sudo reboot`, reconnect, then `systemctl status order` shows
`active` with no manual steps.

---

## Logging

All services log a single JSON object per event to stdout, which journald
captures automatically. Each line answers what happened (`event`, `message`),
when (`timestamp`), which service (`service`), which request (`request_id` +
business `order_id`), and the outcome (`outcome`, `status`).

```bash
journalctl -u order.service -f                 # follow live
journalctl -u order.service -o cat | tail | jq .   # pretty JSON
```

**Request tracing.** Nginx originates an `X-Request-ID` at the front door
(reusing a client-supplied one if present). Every service reads that header,
writes it into every log line, and forwards it on the next hop. A business
`X-Order-ID` rides alongside it. To follow one request end to end:

```bash
journalctl -u order -u inventory -u payment -o cat | grep ORD-XXXXXXXX | jq -c \
  '{t:.timestamp, svc:.service, ev:.event}'
```

The same id appears in the Nginx access log (`trace=`), so the trace spans the
proxy and all three services.

---

## How service discovery works (required explanation)

Services address each other by name (`order.internal`, `inventory.internal`,
`payment.internal`), never by IP. Resolution is performed by the **system
resolver (glibc / NSS)** reading **`/etc/hosts`**, where each name maps to
`127.0.0.1` (all services run on one VM). Nginx resolves `order.internal` the
same way at config load. To change topology, you change the hosts entries, not
the code. Troubleshooting discovery: `getent hosts inventory.internal` should
return `127.0.0.1`; if it returns nothing the name is missing from `/etc/hosts`.

---

## Network security (required explanation)

Two layers. **Primary:** every service binds `127.0.0.1`, so the kernel refuses
external connections to Inventory and Payment regardless of any firewall.
**Secondary:** `ufw` denies all inbound except SSH and port 80. Nginx is the one
public process. Verify with `scripts/verify.sh` (Section 5 proves the internal
ports are refused on the VM's public IP). Full detail and troubleshooting:
`docs/NETWORK-SECURITY.md`.

---

## Dependency management (required explanation)

`order.service` declares `After=inventory.service payment.service` (ordering) and
`Wants=` them (soft dependency, so Order degrades gracefully rather than being
killed if one dies). Beyond ordering, `ExecStartPre=/opt/psenv/scripts/wait-for-deps.sh`
blocks Order until both dependencies answer `/health` — enforcing "Order does not
become operational until its dependencies are available." If a dependency is
stopped, Order returns a clean, traced 502 and recovers automatically when it
returns. Detail: `docs/SYSTEMD.md`.

---

## Troubleshooting

**Git: "Permission denied (publickey)" inside the VM.** You're in the virtiofs
share (`/Users/...`), which carries the Mac's SSH remote. Inside the VM always
`cd ~` first to use the native HTTPS clone. Check with `pwd` (must be
`/home/<user>/...`).

**Service startup failure.** `systemctl status <svc>` then
`journalctl -u <svc> -n 50 --no-pager`. Common causes: code not deployed to
`/opt/psenv`, `/opt/psenv` not owned by `psenv`, venv missing.

**Service dependency failure.** Order stuck `activating` means its readiness gate
is waiting; a dependency isn't healthy. Check `systemctl status inventory payment`
and `journalctl -u order.service | grep wait-for-deps`.

**Reverse proxy failure.** `502 Bad Gateway` = Nginx up but Order down (check
`systemctl status order`). Stock welcome page = default site still enabled
(`sudo rm /etc/nginx/sites-enabled/default`). Always `sudo nginx -t` before reload.

**Service discovery / name resolution failure.** `getent hosts order.internal`
returns nothing → add the `/etc/hosts` entries (Installation step 3). Nginx error
`host not found in upstream` is the same cause.

**Network access failure.** Public IP can't reach port 80 → firewall denying 80
(`sudo ufw status`) or Nginx down. Internal port reachable from outside → a
service is binding `0.0.0.0`; fix `BIND_HOST=127.0.0.1`, reload, restart.

**Missing logs.** Logs go to journald, not files: `journalctl -u <svc>`. Nothing
there → the service never started; check `systemctl status`.

**Invalid routing behaviour.** Unknown endpoints return a JSON 404 from the
service and are logged with `event=not_found`. If you instead get Nginx's HTML
404, the request didn't reach Order (proxy/route issue).

**Inter-service communication failure.** Check the target is up
(`curl http://payment.internal:3003/health`), the name resolves, and the calling
service's logs show a `downstream_error` with the failing target.

---

## Running with Docker Compose

An alternative runtime: the same flow in containers, with Nginx as the only
public entry. (Service A = order, B = inventory, C = payment.)

Start (build first time):

```bash
docker compose up --build -d
```

Test the public route (published on host port 8080):

```bash
curl http://localhost:8080/health

curl -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' -d '{"items":["BOOK-42"],"amount":3500}'
```

<img width="1017" alt="checkout response" src="https://github.com/user-attachments/assets/340e69f2-f479-4404-80db-18603131c129" />

Prove inventory & payment are internal-only (no host port published):

```bash
curl --connect-timeout 3 http://localhost:3002/health   # -> refused
curl --connect-timeout 3 http://localhost:3003/health   # -> refused
```

<img width="1017" alt="connection refused" src="https://github.com/user-attachments/assets/831b2941-5ef5-4f35-aecc-84f8ea2f8a8e" />

View logs:

```bash
docker compose logs            # everything
```

<img width="1469" alt="all logs" src="https://github.com/user-attachments/assets/e7fd9bad-8b9a-45a7-8759-93d882d07eac" />

```bash
docker compose logs order      # one service
```

<img width="1469" alt="order logs" src="https://github.com/user-attachments/assets/d7f937e6-7ec3-407a-8a30-a5b693b4bbc9" />

Stop / restart a single service (failure demo):

```bash
docker compose stop inventory
docker compose start inventory
```

<img width="1469" alt="stop start inventory" src="https://github.com/user-attachments/assets/292d8f5d-20db-4c93-8aff-d1f1d17f3cfc" />

Shut everything down:

```bash
docker compose down
```

<img width="1469" alt="compose down" src="https://github.com/user-attachments/assets/3bcd6ddd-6c6d-45c8-80db-5241606e9d0e" />

How it preserves the production properties: only `nginx` publishes a port
(`8080:80`); inventory/payment publish none and live on an internal bridge
network; services reach each other by Compose service name (`http://inventory:3002`);
logs go to stdout (`docker compose logs`); `X-Request-ID` is traced across all
containers; and `restart: unless-stopped` plus healthcheck-gated `depends_on`
replace the systemd restart/ordering. Full evidence: `docs/CONTAINER_VALIDATION.md`.

Files: `docker-compose.yml`, `Dockerfile` (one shared image, three commands),
`nginx/nginx.compose.conf`, `.dockerignore`. Full run + troubleshoot guide for
both runtimes: `docs/RUNBOOK.md`.

---

## Observability (Compose)

Dev Compose also runs **Prometheus**, **Grafana**, and **Jaeger** so you can
see metrics, alerts, and traces for the checkout pipeline.

| UI | URL (dev) | Login |
|----|-----------|--------|
| Grafana (operating view) | http://localhost:3000 | anonymous Viewer, or `admin` / `admin` |
| Prometheus | http://localhost:9090 | — |
| Jaeger | http://localhost:16686 | — |

**Tip:** if `docker compose up --build -d` fails with
`image "psenv-service:latest": already exists`, build one service first, then
start:

```bash
docker compose build order
docker compose up -d
```

### Open the Grafana cockpit

1. Start the stack (`docker compose up -d`).
2. Open http://localhost:3000 → **Dashboards → MELT → MELT Operating View**.
3. Generate traffic, then watch request rate / latency panels:

```bash
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1"],"amount":4200}'
```

### View metrics

- Per service: `curl -s http://localhost:8080/metrics` is **not** exposed on
  the gateway; scrape targets are internal (`order:3001`, etc.).
- Use Prometheus → **Graph**, or the Grafana dashboard panels.
- Metric contract: `http_requests_total`, `http_request_duration_seconds`,
  `http_errors_total`, `service_up` (see `psenv/services/common/metrics.py`).

### View traces

```bash
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1"],"amount":4200}'
```

Open http://localhost:16686 → Service **`order-service`** → Find Traces.
Full walkthrough: `jaeger/README.md`.

### View logs

```bash
docker compose logs order --tail=50
```

### Confirm alerts

Rules live in `alert-rules.yml` (ServiceDown, HighErrorRate, HighLatency).
Full meaning / reproduce / recover steps: **`docs/ALERTS.md`**.

```bash
curl -s http://localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[].name'

docker compose stop inventory
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | {alertname: .labels.alertname, state, job: .labels.job}'

docker compose start inventory
```

Also check Grafana → **Alert state (firing)** on the MELT dashboard.

### Operational events

Deploy start, load-test markers, failure triggered, and alert fired are
documented in **`docs/EVENTS.md`** (structured logs + Grafana annotations +
alert transitions).

## Documentation index

- `docs/RUNBOOK.md` — **run + troubleshoot guide (both runtimes)** — start here for ops
- `docs/SETUP.md` — first-time environment setup (per teammate)
- `docs/SYSTEMD.md` — service lifecycle, dependencies, failure demos
- `docs/NGINX.md` — reverse proxy deploy and operation
- `docs/NETWORK-SECURITY.md` — protection model and verification
- `docs/PROOF.md` — production-readiness evidence (readiness, recovery, tracing)
- `docs/METRICS.md` — Prometheus metric names, labels, and example PromQL
- `docs/ALERTS.md` — alert PromQL, reproduce, and recovery runbook
- `docs/EVENTS.md` — operational events (deploy, load test, failure, alert)
- `jaeger/README.md` — distributed tracing demo path

---

## Container CI/CD Deployment

### Latest deployed version

<!-- DEPLOYMENT_RECORD:START -->
| Field | Value |
|---|---|
| Commit | [`18e0ecc0b50d9c068b49f86dc8cda2b8f1478ed9`](https://github.com/hunterachieng/group-3-devops-networking/commit/18e0ecc0b50d9c068b49f86dc8cda2b8f1478ed9) |
| Image tag | `sha-18e0ecc` |
| Run | [29041098239](https://github.com/hunterachieng/group-3-devops-networking/actions/runs/29041098239) |

Images published to Docker Hub after each merge to `main`:

```
12517282/group-3-devops-networking-order:sha-18e0ecc
12517282/group-3-devops-networking-inventory:sha-18e0ecc
12517282/group-3-devops-networking-payment:sha-18e0ecc
```
<!-- DEPLOYMENT_RECORD:END -->

### CI pipeline

Every pull request runs three parallel jobs before merge is allowed:

1. **`verify`** (×3 matrix) — installs Python deps, runs `pytest` for each service, builds the Docker image locally
2. **`verify-compose`** — validates the Compose file, builds the full stack, and checks the gateway health endpoint
3. **`publish`** *(main only)* — pushes commit-tagged images to Docker Hub

See [.github/workflows/container-ci-cd.yml](.github/workflows/container-ci-cd.yml).

### Deploy

```bash
cp .env.example .env
export DOCKERHUB_USERNAME=12517282
export APP_NAME=group-3-devops-networking
./scripts/deploy.sh sha-<short-commit-hash>
```

### Verify after deploy

```bash
# Pull images from Docker Hub
docker pull 12517282/group-3-devops-networking-order:sha-<short-commit-hash>
docker pull 12517282/group-3-devops-networking-inventory:sha-<short-commit-hash>
docker pull 12517282/group-3-devops-networking-payment:sha-<short-commit-hash>
```

```bash
# Stack status
docker compose -f docker-compose.prod.yml ps

# Gateway health
curl http://localhost:8080/health

# End-to-end checkout
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1"],"amount":100}' | python3 -m json.tool
```

```bash
# Verify image traceability — labels must show the commit SHA and source repo
docker image inspect 12517282/group-3-devops-networking-order:sha-<short-commit-hash> \
  --format '{{json .Config.Labels}}' | python3 -m json.tool
```

```bash
# Verify internal services are unreachable from the host
curl --connect-timeout 2 http://localhost:3002/health && echo "FAIL" || echo "PASS: inventory not exposed"
curl --connect-timeout 2 http://localhost:3003/health && echo "FAIL" || echo "PASS: payment not exposed"
```

```bash
# Verify containers run as non-root
docker compose -f docker-compose.prod.yml exec order whoami
# Expected: appuser
```

```bash
# Tear down
docker compose -f docker-compose.prod.yml down -v
```