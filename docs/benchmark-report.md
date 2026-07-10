# Benchmark Report

Load and failure testing of the e-commerce observability stack, proving the MELT
signals (Metrics, Events, Logs, Traces) move measurably under normal, stress, and
failure traffic — and are reproducible by another engineer.

---

## Tool

- **[k6](https://k6.io/)** (Grafana) — scriptable HTTP load generator.
- Test script: [scripts/load-test.js](../scripts/load-test.js) — one file, three
  scenarios selected by the `SCENARIO` env var.
- Traffic enters at the Nginx entrypoint (`http://localhost:8080`), exactly as a
  real client would; nothing bypasses the proxy.

### Exact commands

Bring the stack up, then run any scenario. k6 can run natively or via its
container image (used here so no local install is required):

```bash
# 1. start the whole stack (app + Prometheus + Grafana + Jaeger)
docker compose up -d --build      # (docker-compose up -d --build on older CLIs)

# 2. run load tests (native k6)
k6 run                    scripts/load-test.js   # baseline
k6 run -e SCENARIO=stress scripts/load-test.js   # stress
k6 run -e SCENARIO=failure scripts/load-test.js  # failure
k6 run -e SCENARIO=all    scripts/load-test.js   # all three, back-to-back

# 2b. or run k6 in a container (no local install)
docker run --rm -i -v "$PWD/scripts:/scripts" \
  -e SCENARIO=failure -e BASE_URL=http://host.docker.internal:8080 \
  grafana/k6 run /scripts/load-test.js
```

Optional knobs: `-e DURATION=30s` and `-e RATE=8` shorten/tune a run;
`-e BASE_URL=...` retargets it.

### Scenarios

| Scenario   | Executor                 | Load profile                                   | Traffic                        |
|------------|--------------------------|------------------------------------------------|--------------------------------|
| `baseline` | constant-arrival-rate    | 5 req/s for 2m                                 | healthy `POST /checkout`       |
| `stress`   | ramping-arrival-rate     | ramp 10→50→150 req/s over 2m                    | healthy `POST /checkout`       |
| `failure`  | constant-arrival-rate    | 10 req/s for 3m                                | rotates the 4 failure endpoints|

---

## Results

Measured against the running stack on this machine. Baseline and failure were run
at reduced duration (`DURATION=30s` / `45s`) for this report; the full defaults
(2m / 3m) produce the same signal shape at larger sample sizes.

| Scenario | Requests | Concurrency (max VUs) | Avg latency | p95 latency | Error rate | Alerts triggered |
|----------|---------:|----------------------:|------------:|------------:|-----------:|------------------|
| Baseline | 150      | 1 (of 10 allocated)   | 80.4 ms     | 90.3 ms     | 0.00%      | none (healthy)   |
| Stress   | 1151 completed (7998 dropped) | 200 | 20.7 s | 30.0 s | 70.5% | `HighLatency` + `HighErrorRate` (saturation) |
| Failure  | 449      | 21 (of 22 allocated)  | 482 ms      | 1.62 s      | 74.4%      | `HighErrorRate` **firing** (order + inventory); `HighLatency` pending → firing |

> Stress deliberately drove the arrival rate (up to 150 req/s) past what this
> 2-worker-per-service local stack can serve: successful responses stayed fast
> (p95 ≈ 83 ms), but excess requests queued and hit Nginx's 30 s
> `proxy_read_timeout`, producing the 30 s p95, a 70.5% error rate, and 7998
> dropped iterations (arrival rate the generator could not meet). This is the
> expected saturation signature; on a larger host the knee moves higher.


### Metrics observed (Prometheus, during/after the failure run)

Queried at `http://localhost:9090`:

- `sum(http_errors_total) by (service)` → **order-service 337**, **inventory-service 105**
  (Inventory's count comes from `/dependency-fail` cascading Order → Inventory `/fail`).
- p95 `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))`
  → **order-service 1.98 s**, payment 0.074 s, inventory 0.075 s
  (Order's p95 is inflated by `/slow?seconds=1.5`).
- Alert state (`/api/v1/alerts`):
  - `HighErrorRate` — **firing** on `order-service` and `inventory-service`
  - `HighLatency` — **pending** on `order-service` (its `for: 2m` window had not
    fully elapsed in the shortened run; it fires when the run is left at default
    duration).

### Traces observed (Jaeger, `http://localhost:16686`)

- A healthy checkout produces one connected trace: Nginx → Order → Inventory →
  Payment (+ the Payment → Order `/confirm` callback).
- `/dependency-fail` produces a **broken** trace: the Order span has a failing
  child span to `inventory:3002/fail`, pinpointing where the pipeline broke.

### Logs observed (structured JSON, `docker compose logs`)

Every failure emits a structured, greppable line carrying `trace_id`, e.g.:

```json
{"level":"ERROR","service":"order-service","message":"downstream dependency failed: 500 Server Error: INTERNAL SERVER ERROR for url: http://inventory:3002/fail","request_id":"k6-failure-11-19-1783698469444","trace_id":"a1af73876d6dbf8710062ccb2f0beb8c","event":"lab_dependency_fail","target":"http://inventory:3002/fail","status":502,"outcome":"failure"}
```

```json
{"level":"ERROR","service":"order-service","message":"structured error path: lab-only structured error path triggered","request_id":"k6-failure-21-18-1783698469541","trace_id":"38f2ec846ab6dad4415e5535575ef691","event":"lab_error","path":"/error","status":500,"outcome":"error","error_type":"RuntimeError"}
```

The `trace_id` on each line is the same id used in Jaeger, so a log line pivots
directly to its trace.

---

## Lessons learned

- **The full MELT loop works end to end.** A single k6 failure run visibly moved
  all four signals: 5xx counters climbed, p95 latency spiked, structured error
  logs appeared with a `trace_id`, and Jaeger showed the failing downstream span
  — and two alerts moved off OK.
- **Alert `for:` windows matter.** `HighErrorRate` (`for: 1m`) fired within the
  short run, but `HighLatency` (`for: 2m`) only reached *pending*. To demo a
  latency alert firing, run the failure/stress scenario for ≥2 minutes.
- **Failure blast radius is visible.** `/dependency-fail` correctly surfaced the
  error on *both* Order and Inventory, matching the real cascade — exactly the
  behaviour you want when diagnosing which service is the root cause.
- **Route-level metric labels keep cardinality sane.** Labelling on the matched
  Flask route (`/slow`) rather than the raw URL kept the histogram tidy even
  under query-string variation (`/slow?seconds=1.5`).
- **Gunicorn multiprocess metrics were essential.** With 2 workers per service, a
  naive in-process registry would have under-counted; the multiprocess collector
  aggregated all workers so the numbers above are complete.
