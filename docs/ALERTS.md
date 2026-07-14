# Alerting runbook

Prometheus evaluates rules in [`alert-rules.yml`](../alert-rules.yml) every
15 seconds (`evaluation_interval` in `prometheus.yml`). Firing state is visible
in:

- Prometheus UI → **Alerts** — http://localhost:9090/alerts
- Grafana → **MELT Operating View** → “Alert state” / “Firing alert count” —
  http://localhost:3000
- Slack → **`#group-3-alerts`** — fire and resolve messages via Alertmanager

Rules file path inside the container: `/etc/prometheus/alert-rules.yml`
(mounted from the repo root).

---

## Slack delivery (Alertmanager)

Prometheus sends firing/resolved alerts to **Alertmanager**, which posts to
Slack using an Incoming Webhook.

```
Prometheus (alert-rules.yml)
    → Alertmanager (alertmanager.yml)
        → Slack Incoming Webhook → #group-3-alerts
```

| Piece | Detail |
|-------|--------|
| Config | [`alertmanager.yml`](../alertmanager.yml) |
| Secret | `SLACK_WEBHOOK_URL` in `.env` (see [`.env.example`](../.env.example)) |
| Local dev | Set `COMPOSE_PROFILES=alerts` in `.env` so Alertmanager starts with the stack |
| Prod | Same `SLACK_WEBHOOK_URL` in `.env` on the server; `scripts/deploy.sh` exits if missing |
| Channel | `#group-3-alerts` |
| Messages | Firing **and** resolved for all three alerts |
| Local UI | http://localhost:9093 (dev Compose only; not published in prod) |
| Slack links | Point at `localhost:9090` / `:9093` / `:3000` (same machine as Compose) |
| Critical look | `:rotating_light:` critical firing; `:warning:` warning firing; `:white_check_mark:` resolve; red Slack bar when critical |

**Bring-up**

```bash
# Ensure .env contains SLACK_WEBHOOK_URL and COMPOSE_PROFILES=alerts
docker compose up -d alertmanager prometheus
```

**Prove fire + resolve**

```bash
docker compose stop inventory
# wait ~60–90s → Slack should show [FIRING] ServiceDown
docker compose start inventory
# wait until scrape recovers → Slack should show [RESOLVED] ServiceDown
```

---

## Alert 1: ServiceDown

| Field | Value |
|-------|--------|
| **Name** | `ServiceDown` |
| **PromQL** | `up{job=~"order\|inventory\|payment"} == 0` |
| **Pending** | `for: 1m` |
| **Severity** | `critical` |

**What it means**  
Prometheus could not scrape that job’s `/metrics` for at least one minute.
Usually the container is stopped, crash-looping, or unreachable on the Compose
network.

**Possible causes**

- `docker compose stop <service>` or container crash
- Service never became healthy / wrong port in scrape config
- Network partition on `appnet`

**How to reproduce**

```bash
docker compose stop inventory
# wait ~60–90s (rule needs for: 1m)
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | select(.labels.alertname=="ServiceDown")'
```

In Grafana, “Service up/down” for `inventory` turns red and the alert table
lists `ServiceDown`.

**First checks**

1. `docker compose ps` — is the container running?
2. Prometheus → **Status → Targets** — is the job red?
3. `docker compose logs inventory --tail=50`
4. Dependent health: `curl -s http://localhost:8080/health` (order may show
   degraded once readiness paths are exercised)

**How to confirm recovery**

```bash
docker compose start inventory
# wait until healthy + scrape succeeds (~30–60s)
curl -s 'http://localhost:9090/api/v1/query?query=up{job="inventory"}' \
  | jq '.data.result[0].value[1]'   # expect "1"
```

Alert should leave **firing** (and disappear from the Grafana firing table).

---

## Alert 2: HighErrorRate

| Field | Value |
|-------|--------|
| **Name** | `HighErrorRate` |
| **PromQL** | `sum(rate(http_errors_total[2m])) by (service) > 0.1` |
| **Pending** | `for: 1m` |
| **Severity** | `warning` |

**What it means**  
A service is producing more than ~0.1 HTTP 5xx responses per second (2-minute
rate), sustained for 1 minute. `http_errors_total` only counts status ≥ 500
(see `psenv/services/common/metrics.py`).

**Possible causes**

- Downstream timeout / dependency failure returning 502/500
- Lab-only failure endpoints (`/fail`, `/error`, `/dependency-fail`)
- Bug or overload under stress traffic

**How to reproduce**

Hit the failure endpoints at a sustained rate for **>1 minute** so the
2-minute rate window stays above 0.1 req/s of 5xx errors:

```bash
# Option A — k6 failure scenario (recommended, drives all four fault endpoints)
docker run --rm -i -v "$PWD/scripts:/scripts" \
  -e SCENARIO=failure -e BASE_URL=http://host.docker.internal:8080 \
  grafana/k6 run /scripts/load-test.js

# Option B — self-stopping loop (40 requests over ~2 minutes)
for i in $(seq 1 40); do
  curl -s -o /dev/null -w "%{http_code} time=%{time_total}s\n" \
    -X POST http://localhost:8080/fail
  sleep 3
done
```

Watch the error rate climb:
```bash
watch -n5 'curl -s "localhost:9090/api/v1/query?query=sum(rate(http_errors_total[2m]))by(service)" \
  | python3 -c "import sys,json;[print(r[\"metric\"][\"service\"],round(float(r[\"value\"][1]),3)) for r in json.load(sys.stdin)[\"data\"][\"result\"]]"'
```

`HighErrorRate` enters **pending** once rate > 0.1, then **firing** after `for: 1m`.

**First checks**

1. Grafana → **Error rate (5xx)** panel — which `service` label spiked?
2. `docker compose logs <service> --tail=100` — look for `"level":"ERROR"` /
   `downstream_error`
3. Jaeger — open a failing trace (`order-service`) and find the red/error span
4. Prometheus: graph `sum(rate(http_errors_total[2m])) by (service)`

**How to confirm recovery**

Restore dependencies / stop hitting failure endpoints, send a few successful
checkouts, wait ~2 minutes for the rate window to drain. Error-rate panel
should fall and the alert should clear.

```bash
docker compose start inventory   # if you stopped it
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1"],"amount":4200}'
```

---

## Alert 3: HighLatency

| Field | Value |
|-------|--------|
| **Name** | `HighLatency` |
| **PromQL** | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)) > 0.5` |
| **Pending** | `for: 2m` |
| **Severity** | `warning` |

**What it means**  
Estimated p95 request duration for a service is above **0.5 seconds** for at
least 2 minutes.

**Possible causes**

- Slow downstream call or network delay
- Lab-only `/slow` endpoint (`/slow?seconds=N`)
- Stress load (k6 stress or failure scenario)

**How to reproduce**

A **single** slow request is not enough — the alert fires on the p95 across
all requests in a 5-minute window, sustained for 2 minutes. You need a high
volume of slow requests for long enough to shift the p95 and hold it there.

```bash
# Option A — k6 failure scenario (recommended, 3 min of /slow + /fail traffic)
docker run --rm -i -v "$PWD/scripts:/scripts" \
  -e SCENARIO=failure -e BASE_URL=http://host.docker.internal:8080 \
  grafana/k6 run /scripts/load-test.js

# Option B — self-stopping loop (40 requests over ~3 minutes)
for i in $(seq 1 40); do
  curl -s -o /dev/null -w "%{http_code} time=%{time_total}s\n" \
    -X POST "http://localhost:8080/slow?seconds=2"
  sleep 5
done
```

Watch p95 climb in real time:
```bash
watch -n5 'curl -s localhost:9090/api/v1/query \
  --data-urlencode "query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le,service))" \
  | python3 -c "import sys,json;[print(r[\"metric\"].get(\"service\"),round(float(r[\"value\"][1]),3)) for r in json.load(sys.stdin)[\"data\"][\"result\"]]"'
```

Expected sequence:
1. **~30s** of sustained slow traffic → p95 > 0.5s → alert enters **pending**
2. **~2 minutes** held above threshold → alert enters **firing**
3. Stop the loop → p95 drains over the 5m window → alert returns to **OK**

**First checks**

1. Grafana → **p95 latency** — which service is high?
2. Jaeger — find a slow trace; expand spans to see which hop dominates
3. Logs — `duration_ms` on request lines for that `trace_id`
4. Prometheus: graph the same `histogram_quantile(...)` expression

**How to confirm recovery**

Stop slow/failure traffic, wait for the 5m rate window to cool down (~2–5
minutes). p95 should drop below 0.5s and HighLatency should clear.

---

## Quick verification (rules loaded)

```bash
curl -s http://localhost:9090/api/v1/rules \
  | jq -r '.data.groups[].rules[].name'
# expect: ServiceDown, HighErrorRate, HighLatency
```
