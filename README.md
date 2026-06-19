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
restarts on failure, and recovers automatically after a reboot.

---

## Architecture

| Role      | Service identity   | Discovery name       | Port | Public? | Endpoint        |
|-----------|--------------------|----------------------|------|---------|-----------------|
| Order     | order-service      | order.internal       | 3001 | via Nginx | POST /checkout |
| Inventory | inventory-service  | inventory.internal   | 3002 | no      | POST /reserve   |
| Payment   | payment-service    | payment.internal     | 3003 | no      | POST /charge    |

Every service also exposes `GET /health`. Payment confirms back to Order at
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
`docs/SETUP.md`. Full end-to-end deploy on the VM:

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

## Documentation index

- `docs/SETUP.md` — first-time environment setup (per teammate)
- `docs/SYSTEMD.md` — service lifecycle, dependencies, failure demos
- `docs/NGINX.md` — reverse proxy deploy and operation
- `docs/NETWORK-SECURITY.md` — protection model and verification
- `docs/TEAM-UPDATE.md` — how teammates sync after repo changes
