# Trace Evidence — X-Request-ID across all services

This document shows how to verify that a single `X-Request-ID` propagates
through every service for one request.

## How tracing works

```
client ──[X-Request-ID: abc123]──→ nginx
    nginx: if no X-Request-ID, generates one via $request_id
    nginx ──[X-Request-ID: abc123]──→ order:3001/checkout
        order ──[X-Request-ID: abc123]──→ inventory:3002/reserve
            inventory ──[X-Request-ID: abc123]──→ payment:3003/charge
                payment ──[X-Request-ID: abc123]──→ order:3001/confirm (callback)
```

Every service reads `X-Request-ID` from the incoming request and forwards it
on all downstream calls. Each service's structured JSON log includes
`"request_id"` in every line, making the full trace greppable.

## Capture script

Run this after `docker compose up --build -d` and all containers show healthy:

```bash
#!/usr/bin/env bash
set -euo pipefail

RID="trace-demo-$(date +%s)"
echo "=== Sending checkout with X-Request-ID: $RID ==="
echo ""

curl -s -X POST http://localhost:8080/checkout \
  -H "X-Request-ID: $RID" \
  -H "Content-Type: application/json" \
  -d '{"items":["SKU-TRACE-TEST"],"amount":999}' | python3 -m json.tool

echo ""
echo "=== Log lines containing $RID ==="
echo ""
sleep 1

docker compose logs --no-log-prefix 2>/dev/null | grep "$RID" | python3 -m json.tool
```

## Expected output (example)

A successful trace produces log lines from **all four** components. The
`request_id` field is identical across all lines:

```
nginx:
{"timestamp":"2025-06-26T12:00:00+00:00","service":"nginx","method":"POST","uri":"/checkout","status":200,"request_id":"trace-demo-1719403200",...}

order-service (checkout_received):
{"timestamp":"...","service":"order-service","event":"checkout_received","request_id":"trace-demo-1719403200","order_id":"ORD-A1B2C3D4",...}

order-service (reserving_inventory):
{"timestamp":"...","service":"order-service","event":"reserving_inventory","request_id":"trace-demo-1719403200",...}

inventory-service (reserve_received):
{"timestamp":"...","service":"inventory-service","event":"reserve_received","request_id":"trace-demo-1719403200","order_id":"ORD-A1B2C3D4",...}

inventory-service (charging_payment):
{"timestamp":"...","service":"inventory-service","event":"charging_payment","request_id":"trace-demo-1719403200",...}

payment-service (charge_received):
{"timestamp":"...","service":"payment-service","event":"charge_received","request_id":"trace-demo-1719403200","order_id":"ORD-A1B2C3D4",...}

payment-service (confirming_order):
{"timestamp":"...","service":"payment-service","event":"confirming_order","request_id":"trace-demo-1719403200",...}

order-service (order_confirmed):
{"timestamp":"...","service":"order-service","event":"order_confirmed","request_id":"trace-demo-1719403200","order_id":"ORD-A1B2C3D4","source":"payment-service",...}
```

The `X-Order-ID` (e.g. `ORD-A1B2C3D4`) also appears consistently,
providing a second correlation dimension for business-level tracing.

## What to look for

1. **Same `request_id`** in every log line — proves end-to-end propagation.
2. **Four distinct `service` values** — `nginx`, `order-service`, `inventory-service`, `payment-service`.
3. **The callback line** (`order_confirmed` with `source: payment-service`) — proves the full round-trip.
4. **Chronological ordering** — timestamps increase left-to-right through the call chain.
