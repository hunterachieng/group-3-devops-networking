# Container Validation Tests

Run these tests after `docker compose up --build -d` to confirm the stack is healthy.
For Docker install and setup instructions, see [DOCKER_SETUP.md](DOCKER_SETUP.md).

---

## Prerequisites

```bash
docker compose up --build -d
docker compose ps          # all four containers should show "healthy"
```

---

## Test 1 — All containers running and healthy

```bash
docker compose ps
```

Expected: `order`, `inventory`, `payment`, `nginx` all show status `Up` with `(healthy)`.

## Test 2 — Public health endpoint through nginx

```bash
curl -s http://localhost:8080/health | python3 -m json.tool
```

Expected: `{"status": "ok", "service": "order-service"}`.

## Test 3 — Full checkout flow (end-to-end)

```bash
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1","SKU-2"],"amount":4200}' | python3 -m json.tool
```

Expected: nested JSON with `"outcome": "success"` at every level and a `confirm` field showing `"sent"`.

## Test 4 — Internal services unreachable from host

```bash
curl -s --connect-timeout 2 http://localhost:3001/health && echo "FAIL: order exposed" || echo "PASS: order not exposed"
curl -s --connect-timeout 2 http://localhost:3002/health && echo "FAIL: inventory exposed" || echo "PASS: inventory not exposed"
curl -s --connect-timeout 2 http://localhost:3003/health && echo "FAIL: payment exposed" || echo "PASS: payment not exposed"
```

Expected: all three print `PASS`.

## Test 5 — Internal DNS resolution (container-to-container)

```bash
docker compose exec order sh -c "python -c \"import urllib.request; print(urllib.request.urlopen('http://inventory:3002/health').read().decode())\""
```

Expected: `{"status": "ok", "service": "inventory-service"}`.

## Test 6 — Trace header propagation (X-Request-ID)

```bash
RID="test-trace-$(date +%s)"
curl -s -X POST http://localhost:8080/checkout \
  -H "X-Request-ID: $RID" \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-A"],"amount":100}'

sleep 1
docker compose logs --no-log-prefix 2>/dev/null | grep "$RID"
```

Expected: the same `$RID` appears in log lines from nginx, order-service, inventory-service, and payment-service.

## Test 7 — Readiness endpoint (liveness vs readiness distinction)

### 7a — All healthy, readiness passes

```bash
curl -s http://localhost:8080/ready | python3 -m json.tool
```

Expected: `200` with `"status": "ready"` and `"dependencies": {"inventory": true}`.

### 7b — Kill Payment, both Inventory and Order report not-ready (transitive)

```bash
docker compose stop payment
sleep 3

# Inventory readiness fails (can't reach Payment):
docker compose exec inventory sh -c "curl -s http://localhost:3002/ready" | python3 -m json.tool
# Expected: 503, {"status": "not_ready", "dependencies": {"payment": false}}

# Order readiness also fails (Order checks Inventory's /ready, which is 503):
curl -s http://localhost:8080/ready | python3 -m json.tool
# Expected: 503, {"status": "not_ready", "dependencies": {"inventory": false}}

# But liveness is fine for both — the processes are alive:
docker compose exec inventory sh -c "curl -s http://localhost:3002/health" | python3 -m json.tool
# Expected: 200, {"status": "ok"}

curl -s http://localhost:8080/health | python3 -m json.tool
# Expected: 200, {"status": "ok"}
```

### 7c — Kill Inventory, Order reports not-ready

```bash
docker compose start payment
sleep 3
docker compose stop inventory
sleep 3

curl -s http://localhost:8080/ready | python3 -m json.tool
# Expected: 503, {"status": "not_ready", "dependencies": {"inventory": false}}

curl -s http://localhost:8080/health | python3 -m json.tool
# Expected: 200, {"status": "ok"} — still alive
```

### 7d — Restart, readiness recovers automatically

```bash
docker compose start inventory
sleep 5

curl -s http://localhost:8080/ready | python3 -m json.tool
# Expected: 200, {"status": "ready", "dependencies": {"inventory": true}}
```

### 7e — Payment readiness (always ready, no hard dependencies)

```bash
docker compose exec payment sh -c "curl -s http://localhost:3003/ready" | python3 -m json.tool
# Expected: 200, {"status": "ready", "dependencies": {}}
```

Key takeaway: `/health` = "am I alive?" (200 if the process runs), `/ready` = "can I serve real traffic?" (503 when a downstream is down).

## Test 8 — Callback coupling (no deadlock, best-effort confirm)

### 8a — Callback completes (full round-trip)

```bash
curl -s -X POST http://localhost:8080/checkout \
  -H "X-Request-ID: callback-test-1" \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1"],"amount":100}' | python3 -m json.tool
```

Expected: `"confirm": "sent"` in the nested response — proves Payment called Order `/confirm` successfully.

### 8b — No deadlock under concurrent load

```bash
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8080/checkout \
    -d '{"items":["SKU-'$i'"],"amount":100}' &
done
wait
echo "All 20 completed without deadlock"
```

Expected: all 20 complete — no request hangs forever. With Gunicorn
`--workers 2 --threads 4` (8 concurrent slots per service), some requests
may return 502 under this burst because the worker pool is saturated and
the 5-second `DOWNSTREAM_TIMEOUT` expires. This is normal capacity
limiting, not a deadlock. The key evidence is that every request finishes
(success or 502) rather than hanging indefinitely, which would happen
with a single-threaded server where the callback blocks the only thread.

### 8c — Callback is best-effort (Order down during callback)

```bash
docker compose stop order
sleep 2

# Call Payment directly — charge succeeds even though callback fails:
docker compose exec inventory sh -c \
  "curl -s -X POST http://payment:3003/charge \
    -H 'Content-Type: application/json' \
    -H 'X-Request-ID: callback-fail-test' \
    -d '{\"order_id\":\"ORD-TEST\",\"amount\":50}'" | python3 -m json.tool
# Expected: {"outcome": "success", "confirm": "failed"}

# Verify the warning was logged:
docker compose logs payment | grep "callback-fail-test"
# Expected: confirm_error log line

docker compose start order
sleep 5
```

### 8d — Acyclic startup (no circular dependency)

```bash
docker compose down
docker compose up -d 2>&1 | head -20
```

Expected: payment and inventory start first, then order (waits for both healthy), then nginx. No "circular dependency" error.

## Test 9 — Dependency recovery (service restart)

```bash
# Kill inventory:
docker compose stop inventory
sleep 2

# Order degrades gracefully (502, not crash):
curl -s -X POST http://localhost:8080/checkout | python3 -m json.tool
# Expected: 502 with "inventory service unavailable"

# Order liveness still passes:
curl -s http://localhost:8080/health | python3 -m json.tool
# Expected: 200

# Restart inventory — order recovers automatically:
docker compose start inventory
sleep 5
curl -s -X POST http://localhost:8080/checkout | python3 -m json.tool
# Expected: 200 with "outcome": "success"
```

## Test 10 — Machine-verifiable distributed trace

This test produces a concrete, grep-able log excerpt that confirms the same
`X-Request-ID` appears in all four components (nginx, order, inventory, payment).

```bash
RID="trace-verify-$(date +%s)"

curl -s -X POST http://localhost:8080/checkout \
  -H "X-Request-ID: $RID" \
  -H "Content-Type: application/json" \
  -d '{"items":["SKU-TRACE"],"amount":99}' | python3 -m json.tool

sleep 1

echo "--- nginx ---"
docker compose logs --no-log-prefix nginx   2>/dev/null | grep "$RID"
echo "--- order ---"
docker compose logs --no-log-prefix order   2>/dev/null | grep "$RID"
echo "--- inventory ---"
docker compose logs --no-log-prefix inventory 2>/dev/null | grep "$RID"
echo "--- payment ---"
docker compose logs --no-log-prefix payment 2>/dev/null | grep "$RID"
```

Expected output (one matching log line per section):

```
--- nginx ---
{"timestamp":"...","service":"nginx",...,"request_id":"trace-verify-<epoch>",...}
--- order ---
{"timestamp":"...","service":"order-service","request_id":"trace-verify-<epoch>",...}
--- inventory ---
{"timestamp":"...","service":"inventory-service","request_id":"trace-verify-<epoch>",...}
--- payment ---
{"timestamp":"...","service":"payment-service","request_id":"trace-verify-<epoch>",...}
```

The trace is verified if all four sections are non-empty. An empty section means that
component did not log the request ID and the trace chain is broken.
