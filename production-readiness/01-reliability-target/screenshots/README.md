# Reliability target evidence screenshots

Dashboard: CloudWatch → `devops-g3-iac-production-readiness`

| File | What it shows |
|---|---|
| `cloudwatch-production-readiness-dashboard-inventory-drill.png` | Full dashboard during/after inventory-outage drill (~11:40–12:05 UTC): 5xx spike, checkout failures, availability drop to 0%, recovery to 100% |

**SLI sources visible in this capture:**

- **Availability** — bottom panel: checkout availability % from log metrics
- **Latency** — top-right: ALB p95 target response time (below 500 ms SLO line during drill)
- **Saturation** — middle: order CPU/memory (Container Insights)
- **Request volume** — top-left: ALB 2xx vs 5xx during probe traffic

See `../reliability-target.md` for SLO definitions and query paths.
