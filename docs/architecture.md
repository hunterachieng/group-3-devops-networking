# Architecture

This document describes the service architecture and how observability (MELT —
Metrics, Events, Logs, Traces) flows through the system.

Service map used throughout the assignment: **A = order**, **B = inventory**,
**C = payment**.

---

## 1. Service architecture

Three independent Flask services form an e-commerce checkout pipeline, fronted by
an Nginx reverse proxy and observed by a Prometheus / Grafana / Jaeger stack.

| Role      | Service identity  | Compose name | Port | Public?    | Primary endpoint |
|-----------|-------------------|--------------|------|------------|------------------|
| Order     | order-service     | `order`      | 3001 | via Nginx  | `POST /checkout` |
| Inventory | inventory-service | `inventory`  | 3002 | no         | `POST /reserve`  |
| Payment   | payment-service   | `payment`    | 3003 | no         | `POST /charge`   |

Only **Nginx** publishes a host port (`8080 -> 80`) and it only proxies to Order.
Inventory and Payment are internal: they are never proxied and are unreachable
from outside the Compose network. Services discover each other by Compose service
name (DNS), never by hardcoded IP. Each service runs under Gunicorn (2 workers ×
4 threads), not the Flask dev server.

Observability stack:

| Component  | Image                        | Host port | Purpose                          |
|------------|------------------------------|-----------|----------------------------------|
| Prometheus | `prom/prometheus`            | 9090      | scrapes `/metrics`, evaluates alerts |
| Grafana    | `grafana/grafana`            | 3000      | dashboards + alert state         |
| Jaeger     | `jaegertracing/all-in-one`   | 16686     | distributed trace UI (OTLP in)   |

Prometheus persists its TSDB to the named volume `prometheus-data`; Grafana to
`grafana-data`.

---

## 2. Request flow

A checkout traverses all three services and returns a confirmation via a
callback from Payment to Order:

```
Client
  |  POST /checkout                                  (public, host :8080)
  v
+-----------+
|   Nginx   |  :80   (the ONLY publicly-bound process; mints X-Request-ID)
+-----------+
  |  proxy_pass -> order:3001
  v
+-----------+   POST /reserve   +-------------+   POST /charge   +-----------+
|   Order   | ----------------> |  Inventory  | ---------------> |  Payment  |
|   :3001   |                   |    :3002    |                  |   :3003   |
+-----------+                   +-------------+                  +-----------+
  ^                                                                    |
  |            POST /confirm   (payment confirmed, order done)         |
  +--------------------------------------------------------------------+

Synchronous responses unwind back up the chain: Payment -> Inventory -> Order -> Nginx -> Client.
```

- `X-Request-ID` is the **business correlation id**, minted by Nginx (or reused
  if the caller supplies one) and threaded through every hop.
- W3C `traceparent` is the **distributed-trace** propagation, injected
  automatically by the OpenTelemetry `requests` instrumentation.

---

## 3. Telemetry flow (MELT)

```
                         +------------------------------------+
                         |  order / inventory / payment       |
                         |  (Flask + Gunicorn)                |
                         |                                    |
  metrics.py  --------->  | /metrics  (prometheus_client)     |
  tracing.py  --------->  | OTLP spans (Flask + requests)     |
  logging_setup.py ---->  | JSON logs -> stdout               |
                         +------------------------------------+
                             |            |             |
              scrape :3001/2/3            | OTLP/HTTP   | docker logs
              (by service name)           | :4318       | (stdout)
                             v            v             v
                     +------------+  +---------+   +-----------------+
                     | Prometheus |  | Jaeger  |   | docker compose  |
                     |  :9090     |  | :16686  |   |     logs        |
                     | + alerts   |  |         |   | (JSON, greppable|
                     +------------+  +---------+   |  by request_id/ |
                          |                        |  trace_id)      |
                   datasource / alert state        +-----------------+
                          v
                     +------------+
                     |  Grafana   |  :3000  (dashboards + alert panel)
                     +------------+
```

### Metrics (the "M")
Shared middleware in [psenv/services/common/metrics.py](../psenv/services/common/metrics.py)
records, per request:

- `http_requests_total{service,method,route,status_code}` — counter
- `http_request_duration_seconds{service,method,route}` — histogram (enables p95)
- `http_errors_total{service,route}` — counter, 5xx only
- `service_up{service}` — gauge (1 = up)

Prometheus scrapes each service's `/metrics` by Compose service name and stores
samples in the `prometheus-data` volume.

### Events (the "E")
Operationally significant moments are emitted as structured events (deploy,
load-test start/complete, failure triggered, alert fired) via the same JSON log
channel and/or Grafana annotations. See [docs/EVENTS.md](EVENTS.md).

### Logs (the "L")
[psenv/services/common/logging_setup.py](../psenv/services/common/logging_setup.py)
renders every log line as a single JSON object to stdout with a stable schema:
`timestamp`, `level`, `service`, `message`, `request_id`, `trace_id`, `span_id`,
plus per-event fields (`method`, `path`, `status`, `duration_ms`, `outcome`, …).
Because `trace_id` is injected automatically from the active span, any log line
can be pivoted straight to its trace in Jaeger.

### Traces (the "T")
[psenv/services/common/tracing.py](../psenv/services/common/tracing.py)
auto-instruments Flask and `requests` and exports spans over OTLP/HTTP to Jaeger
(`:4318`). A single checkout produces one connected trace spanning
Nginx → Order → Inventory → Payment (and the Payment → Order callback).

### Alerting
[alert-rules.yml](../alert-rules.yml) defines three rules evaluated by Prometheus
and surfaced in Grafana. Alertmanager delivers the same alerts to Slack
`#group-3-alerts` (fire + resolve) using `SLACK_WEBHOOK_URL`:

| Alert          | Condition (summary)                                             |
|----------------|----------------------------------------------------------------|
| `ServiceDown`  | `up{job=~"order|inventory|payment"} == 0` for 1m               |
| `HighErrorRate`| `sum(rate(http_errors_total[2m])) by (service) > 0.1` for 1m   |
| `HighLatency`  | p95 of `http_request_duration_seconds_bucket` > 0.5s for 2m    |

See [docs/ALERTS.md](ALERTS.md) for the Slack delivery path and how to test it.

---

## 4. Controlled-failure endpoints (lab-only)

To prove telemetry moves under failure, each service registers fault-injection
routes from [psenv/services/common/failures.py](../psenv/services/common/failures.py),
**only** when `ENABLE_FAILURE_ENDPOINTS` is truthy (set in `docker-compose.yml`,
unset in `docker-compose.prod.yml`). Nginx exposes them by proxying to Order:

| Endpoint           | Behaviour                        | MELT signal driven                    |
|--------------------|----------------------------------|---------------------------------------|
| `/fail`            | returns 500                      | `http_errors_total` ↑ → `HighErrorRate` |
| `/slow?seconds=N`  | sleeps N seconds (default 1s)    | duration histogram ↑ → `HighLatency`  |
| `/error`           | structured error path → 500      | 5xx + `event=lab_error` log line      |
| `/dependency-fail` | calls downstream `/fail` → 502   | broken cross-service span in Jaeger   |

`/dependency-fail` on Order calls Inventory's `/fail`, so the failure — and the
resulting error-rate spike — appears on **both** services, and the trace shows
exactly where the pipeline broke.

---

## 5. Known limitations

- **Failure endpoints are not authenticated** — they are gated only by an env
  flag and must never be enabled in a real deployment.
- **Logs are not shipped to a store** — they go to container stdout only
  (`docker compose logs`); there is no Loki/Elasticsearch aggregation, so log
  search is `grep`/`jq` based.
- **Grafana runs with anonymous viewer access** and default admin credentials
  for lab convenience — not production-safe.
- **Single-node stack** — Prometheus, Grafana, and Jaeger are all-in-one, single
  replica, with no HA or long-term storage; Jaeger keeps traces in memory.
- **Metrics cardinality** is kept low by labelling on the matched Flask route
  rule rather than the raw path.
- **The Payment → Order callback is best-effort**; a failed confirm is logged but
  does not fail the charge, so a confirm failure is visible in logs/traces but
  not as a checkout error.
