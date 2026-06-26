# Proof pack (production-readiness evidence)

Evidence for the refinements raised in review: readiness vs liveness, production
serving, callback safety, and dependency-recovery. Run each command on the VM and
paste your own output; representative output is shown so you know what to expect.

---

## 1. Production serving (Gunicorn, not the Flask dev server)

The services run under **Gunicorn** (a production WSGI server), configured in the
systemd units with multiple workers and threads. Confirm:

```bash
systemctl show order.service -p ExecStart --no-pager
journalctl -u order.service | grep -i gunicorn | head -3
```

Representative output:

```
[INFO] Starting gunicorn 23.0.0
[INFO] Listening at: http://127.0.0.1:3001
[INFO] Booting worker with pid: ...
```

---

## 2. Readiness vs liveness

`/health` is **liveness** (the process is up). `/ready` is **readiness** (the
service can do useful work, i.e. its required downstream is reachable). A load
balancer should route on `/ready`.

Test by stopping a dependency and comparing the two on the service above it:

```bash
sudo systemctl stop payment

curl -s -o /dev/null -w "inventory /health -> %{http_code}\n" http://127.0.0.1:3002/health
curl -s -o /dev/null -w "inventory /ready  -> %{http_code}\n" http://127.0.0.1:3002/ready
curl -s http://127.0.0.1:3002/ready

sudo systemctl start payment        # restore
```

Representative output (Payment down):

```
inventory /health -> 200
inventory /ready  -> 503
{"status":"not_ready","dependencies":{"payment":false}}
```

Liveness stays 200 (the process is fine); readiness correctly reports 503 because
Payment is unavailable. The readiness contract is **transitive**: Order's
`/ready` checks Inventory's `/ready`; Inventory's `/ready` checks Payment's
`/health`; Payment's `/ready` is always ready (its callback to Order is
best-effort). So when Payment is down, Inventory reports not-ready and Order — which
checks Inventory's `/ready` — reports not-ready too, giving one gateway-level
`/ready` that reflects the whole pipeline. Response shape:

```
200  {"status": "ready",     "dependencies": {"inventory": true}}
503  {"status": "not_ready", "dependencies": {"inventory": false}}
```

---

## 3. Callback coupling does not deadlock under load

Payment calls Order's `/confirm` while Order may still be waiting on the
Inventory->Payment response. This does not deadlock because Gunicorn serves each
service with **2 workers x 4 threads = 8 concurrent handlers**. The inbound
`/confirm` on Order is handled by a free worker/thread independent of the one
awaiting the downstream response, so the callback never blocks behind the request
that triggered it. The callback is also best-effort: if Order is briefly
unavailable, Payment logs a warning and still completes the charge (it does not
hang waiting). Confirm concurrency:

```bash
systemctl show order.service -p ExecStart --no-pager   # shows --workers 2 --threads 4
```

---

## 4. Dependency recovery (death + restart, no manual rebuild)

Two cases. **Deliberate stop** stays stopped (you told it to); **a crash** is
auto-restarted by `Restart=on-failure`.

Crash + auto-recovery:

```bash
# simulate a crash (SIGKILL, not a clean stop)
sudo systemctl kill -s SIGKILL inventory
sleep 3
systemctl status inventory --no-pager | grep -E "Active|Main PID"   # back to active (running)

# the order flow works again with no manual intervention
curl -s -X POST http://localhost/checkout -d '{}' \
  | python3 -c "import sys,json;print('recovered:', json.load(sys.stdin).get('outcome'))"
```

Representative: `inventory` returns to `active (running)` within ~2s, and the
checkout returns `recovered: success`.

Deliberate stop + graceful degradation + recovery:

```bash
sudo systemctl stop inventory
curl -s -X POST http://localhost/checkout -d '{}'     # clean 502, Order stays up
journalctl -u order.service -o cat | tail -3          # shows event=downstream_error
sudo systemctl start inventory
sleep 2
curl -s -X POST http://localhost/checkout -d '{}'     # success again
```

Order returns a clean 502 (not a crash) while Inventory is down, and recovers
automatically when Inventory returns - no restart of Order required.

---

## 5. Trace survives the full flow

One request with a known id, correlated across Nginx and all three services:

```bash
curl -s -X POST http://localhost/checkout \
  -H 'X-Request-ID: proof-trace-001' -d '{"items":["BOOK-42"],"amount":3500}' >/dev/null

journalctl -u order -u inventory -u payment -o cat \
  | grep proof-trace-001 \
  | python3 -c "import sys,json
for l in sys.stdin:
    try:
        e=json.loads(l); print(f\"{e['service']:18} {e['event']}\")
    except: pass"
sudo grep proof-trace-001 /var/log/nginx/ecommerce_access.log
```

Representative output (one request, one id, every hop):

```
order-service      checkout_received
order-service      reserving_inventory
inventory-service  reserve_received
inventory-service  stock_reserved
inventory-service  charging_payment
payment-service    charge_received
payment-service    payment_captured
payment-service    confirming_order
order-service      order_confirmed
order-service      checkout_completed
... ecommerce_access.log: ... trace=proof-trace-001 ...
```

---

## 6. The remaining proof-pack items

These are already covered by `scripts/verify.sh` and `docs/NETWORK-SECURITY.md`:

- **Only Nginx is public / services bind internally** -> `verify.sh` Sections 2 & 5,
  and `sudo ss -ltnp | grep -E ':(80|3001|3002|3003)'`.
- **Firewall active** -> `sudo ufw status verbose`.
- **Reboot persistence** -> `sudo reboot`, then `systemctl status` + `verify.sh`.