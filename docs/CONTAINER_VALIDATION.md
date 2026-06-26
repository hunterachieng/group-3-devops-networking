# Container validation

Evidence that the containerized system preserves the production behavior.
Run each block on a machine with Docker, and paste the actual output (or a
screenshot) under each "Result" heading.

Service-name mapping: **Service A = order, Service B = inventory,
Service C = payment.** Public route is `POST /checkout` (and `GET /health`),
published on host port **8080**.

---

## 1. Start the system

```bash
docker-compose up --build -d
```

Result (expected): images build, then `Created`/`Started` for order, inventory,
payment, nginx.

---

## 2. Confirm containers are running

```bash
docker compose ps or docker ps
```

Result (expected): four services listed, all `running`; order/inventory/payment
show `(healthy)`. Only `nginx` shows a published port (`0.0.0.0:8080->80/tcp`).

---

## 3. Public entry point works

```bash
curl -i http://localhost:8080/health
curl -i -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' -d '{"items":["BOOK-42"],"amount":3500}'
```

Result (expected): `HTTP/1.1 200 OK`; `/checkout` returns nested JSON with
`"outcome": "success"` and an `order_id`.

---

## 4. Service B and C are NOT directly exposed

```bash
curl -i --connect-timeout 3 http://localhost:3002/health
curl -i --connect-timeout 3 http://localhost:3003/health
```

Result (expected): `Connection refused` (or timeout) for both. Neither service
publishes a host port, so the host cannot reach them.

---

## 5. Internal service discovery works (inside the Compose network)

```bash
docker compose exec order     curl -fsS http://inventory:3002/health
docker compose exec inventory curl -fsS http://payment:3003/health
```

Result (expected): each returns `{"service":"...","status":"ok"}` with HTTP 200,
proving containers resolve each other by Compose service name.

---

## 6. Trace one request through the system

```bash
curl -i -X POST http://localhost:8080/checkout \
  -H 'X-Request-ID: demo-container-001' \
  -H 'Content-Type: application/json' -d '{"items":["BOOK-42"],"amount":3500}'

docker compose logs | grep demo-container-001
```

Result (expected): `demo-container-001` appears in order, inventory, payment, and
nginx logs. (Verified against the real config: the id flows through
checkout_received -> reserving_inventory -> stock_reserved -> charging_payment ->
payment_captured -> confirming_order -> order_confirmed -> checkout_completed.)

---

## 7. Stop Service B: clean failure, then recovery

```bash
docker compose stop inventory

curl -i -X POST http://localhost:8080/checkout \
  -H 'X-Request-ID: fail-service-b-001' -d '{}'
docker compose logs order | grep fail-service-b-001
```

Result (expected): the request returns **HTTP 502** with
`"outcome": "failure"` and an error naming the unavailable downstream; order
stays up and logs a `downstream_error` event. (Order uses a soft dependency, so
it degrades gracefully instead of crashing.)

Recover:

```bash
docker compose start inventory
sleep 3
curl -i -X POST http://localhost:8080/checkout -d '{}'
```

Result (expected): `HTTP/1.1 200 OK` again, with no restart of order needed.

---

## Shut down

```bash
docker compose down           
docker compose down -v 
```
