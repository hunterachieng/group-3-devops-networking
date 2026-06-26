# Callback Coupling and Dependency Recovery

## Payment → Order callback

After charging the customer, Payment calls `POST /confirm` back to Order to
close the loop. This is the only inter-service cycle in the system.

### Why it does not deadlock

```
client → nginx → Order → Inventory → Payment ──callback──→ Order /confirm
                  (waiting for Inventory response)            (separate request)
```

1. **Gunicorn runs multiple workers and threads** (`--workers 2 --threads 4`).
   The thread serving `/checkout` blocks on the downstream HTTP call to
   Inventory, but other threads are free to accept the `/confirm` callback.
   A single-threaded server would deadlock under concurrent load when all
   threads are waiting on downstream responses — Gunicorn's thread pool
   prevents this.

2. **Payment treats the callback as best-effort.** If Order is unreachable
   when Payment tries to confirm, Payment catches the exception, logs a
   warning, and still returns `200` to Inventory. The charge is not rolled
   back. This means:
   - The `/charge` endpoint never fails because of Order.
   - `depends_on` in docker-compose does NOT list Order for Payment,
     preserving the no-cycle startup rule.

3. **Order can miss the callback and still function.** A missed callback is
   logged (`confirm_error`, level WARNING), but the checkout response
   already returned to the client from Order's perspective. The callback is
   a notification, not a gate.

### Compose dependency graph (no cycle)

```
nginx  ──depends_on──→  order  ──depends_on──→  inventory
                          │                        │
                          └──depends_on──→  payment (no depends_on — starts first)
                                               │
                          order  ←── runtime callback (not depends_on)┘
```

Payment only calls Order at runtime, not at startup. The `depends_on` graph
is acyclic: `payment` and `inventory` start first (in parallel), then
`order` (once both are healthy), then `nginx`.

---

## Readiness vs Liveness

| Endpoint | What it checks | When it fails |
|----------|---------------|---------------|
| `GET /health` | Process is alive and can serve HTTP | Process crashed or hung |
| `GET /ready`  | Process is alive AND downstream deps respond | A dependency is down |

- **Order** `/ready` checks Inventory's `/ready` (transitive).
- **Inventory** `/ready` checks Payment's `/health`.
- **Payment** `/ready` always returns 200 (its callback to Order is best-effort).

Readiness is transitive: if Payment is down, Inventory reports not-ready
(503), so Order's check against Inventory's `/ready` also fails — Order
reports not-ready too. This gives a single endpoint at the nginx layer
(`GET /ready`) that reflects the health of the entire pipeline.

The Compose healthcheck uses `/health` (liveness), not `/ready`, for the
`depends_on` gate. This is intentional: using `/ready` in `depends_on`
would cause cascading restarts when a single service goes down. Instead,
`/ready` is exposed through nginx for load balancer or orchestrator use.

---

## Dependency recovery

When a downstream service dies and restarts:

1. **During the outage:** the upstream returns a clean `502` with a
   descriptive error. It does NOT crash, panic, or hang. The liveness
   probe (`/health`) keeps passing. The readiness probe (`/ready`)
   returns `503`.

2. **After restart:** Compose's `restart: unless-stopped` brings the
   container back. The upstream's next request to the downstream
   succeeds — no manual restart or cache flush needed. `/ready`
   returns `200` again.

3. **No state to reconcile:** services are stateless; there is no
   connection pool, circuit breaker state, or cache that needs
   invalidation. Each HTTP request is independent.

See `CONTAINER_VALIDATION.md` Test 9 for the exact commands to verify
this.
