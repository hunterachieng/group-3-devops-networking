# Operational events (MELT “E”)

Events mark **moments that change system behavior**, so reviewers can connect
metrics/logs/traces to what operators did. This lab records at least three
event types below.

Events appear as:

1. **Structured JSON logs** (`docker compose logs`) via `log_event(...)` /
   request lifecycle lines (`request_id`, `trace_id`, `event`, …)
2. **Grafana dashboard annotations** (manual markers on MELT Operating View
   during demos — Dashboard settings → Annotations, or the annotation
   pencil on a panel timeline)
3. **Alert transitions** in Prometheus/Grafana when an alert fires or clears

---

## Event catalog (minimum three)

### 1. Stack / deploy started

| | |
|--|--|
| **When** | `docker compose up -d` (or prod deploy via `scripts/deploy.sh`) |
| **Evidence** | Containers move to `running`/`healthy` (`docker compose ps`); Grafana and Prometheus become reachable |
| **Demo note** | Annotate Grafana: “deploy started” at stack bring-up |

### 2. Load test started / completed

| | |
|--|--|
| **When** | Person 4 runs `scripts/load-test.js` (k6) normal/stress/failure scenarios |
| **Evidence** | Request-rate and latency panels rise; benchmark rows in `docs/benchmark-report.md` |
| **Demo note** | Annotate “load test started” / “load test completed” on the MELT dashboard timeline |

### 3. Failure triggered

| | |
|--|--|
| **When** | Controlled failure: e.g. `docker compose stop inventory`, or Person 4 `/fail` / `/slow` |
| **Evidence** | Checkout returns 5xx/502; error logs (`downstream_error`); Jaeger shows failed/slow span; Grafana error or latency panels move |
| **Demo note** | Annotate “failure triggered” at the stop/`/fail` moment |

### 4. Alert fired (recommended fourth)

| | |
|--|--|
| **When** | A rule in `alert-rules.yml` enters **firing** (e.g. ServiceDown after inventory stopped ≥ 1m) |
| **Evidence** | Prometheus `/alerts`; Grafana “Alert state (firing)” table; `ALERTS{alertstate="firing"}` |
| **Demo note** | Annotate “alert fired: ServiceDown” when the table populates |

---

## Suggested demo timeline

```
t0  docker compose up -d          → event: deploy/stack started
t1  successful checkout           → metrics + full Jaeger trace
t2  (optional) k6 normal/stress   → event: load test started/completed
t3  docker compose stop inventory → event: failure triggered
t4  wait ≥ 1m                     → event: alert fired (ServiceDown)
t5  docker compose start inventory→ recovery; alert clears
```

Person 4 owns load-test commands and the benchmark report; Person 3 owns
alert definitions and pointing reviewers at Grafana/Prometheus for events
3–4.
