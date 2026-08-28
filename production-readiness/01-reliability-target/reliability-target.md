# Reliability Target — Customer Checkout

**Critical user journey:** A customer completes a purchase via `POST /checkout` through the public ALB, which triggers Order → Inventory → Payment and the Payment → Order `/confirm` callback.

**Environment:** `devops-g3-iac-*` ECS Fargate stack, `us-west-1`

**Dashboard:** CloudWatch → Dashboards → `devops-g3-iac-production-readiness`

---

## SLIs, SLOs, and Error Budget

| SLI | Definition | SLO (7-day window) | Error budget | Primary measurement |
|---|---|---|---|---|
| **Checkout availability** | Ratio of successful checkouts to total checkout attempts | **99.5%** | ~50 minutes of failed checkouts per week | Log-derived metric: `CheckoutSuccess / (CheckoutSuccess + CheckoutFailure)` in namespace `devops-g3-iac/Checkout` |
| **Checkout latency** | p95 time from ALB to order target for all requests | **p95 ≤ 500 ms** | ~0.5% of requests may exceed threshold | ALB metric `TargetResponseTime` (stat: p95) on order target group |
| **Pipeline correctness** | Checkouts that emit `checkout_completed` in order logs (full A→B→C path succeeded from order's perspective) | **99.0%** | ~1% of attempts may fail or stall | CloudWatch Logs Insights on `/ecs/devops-g3-iac/order` |

### Error budget calculation (availability)

For a 7-day window (10,080 minutes):

```
Budget = (1 - SLO) × window = (1 - 0.995) × 10,080 min ≈ 50.4 minutes of bad checkout minutes
```

Track consumption with the dashboard widget **"Checkout availability SLI (% successful checkouts from logs)"**. When availability drops below 99.5% over a rolling 7-day period, the budget is being consumed.

---

## Where measurements come from

### 1. Checkout availability (log-derived SLI)

Terraform creates log metric filters on `/ecs/devops-g3-iac/order`:

| Metric | Log pattern | Meaning |
|---|---|---|
| `CheckoutSuccess` | `"event": "checkout_completed"` | Checkout returned HTTP 200 |
| `CheckoutFailure` | `"event": "downstream_error"` | Checkout returned HTTP 502 (inventory/payment unreachable) |

**CloudWatch dashboard query:** see widget "Checkout availability SLI" — metric math:

```
IF(m1+m2 > 0, 100 * m1 / (m1+m2), 100)
```

where `m1 = CheckoutSuccess`, `m2 = CheckoutFailure`.

### 2. Checkout latency (ALB SLI)

**Console path:** CloudWatch → Metrics → ApplicationELB → Per AppELB, per TG Metrics → `TargetResponseTime`

**Dimensions:**

- LoadBalancer: output of `terraform output` / ALB module (`load_balancer_arn_suffix`)
- TargetGroup: order target group suffix

**CLI example:**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=app/devops-g3-iac-alb/XXXXXXXX \
              Name=TargetGroup,Value=targetgroup/devops-g3-iac-order-tg/XXXXXXXX \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --extended-statistics p95 \
  --region us-west-1
```

Replace `XXXXXXXX` with your suffixes from the AWS console or `terraform state show module.alb.aws_lb.this`.

### 3. Pipeline correctness (Logs Insights)

**Console path:** CloudWatch → Log groups → `/ecs/devops-g3-iac/order` → Logs Insights

```sql
fields @timestamp, event, request_id, order_id, outcome, status
| filter event in ["checkout_received", "checkout_completed", "downstream_error"]
| sort @timestamp desc
| limit 200
```

**End-to-end proof query** (correlate across services):

```sql
fields @timestamp, service, event, request_id, order_id
| filter request_id = "YOUR-REQUEST-ID"
| sort @timestamp asc
```

Run the same `request_id` filter on `/ecs/devops-g3-iac/inventory` and `/ecs/devops-g3-iac/payment`.

### 4. Supplementary ALB signals

| Metric | Use |
|---|---|
| `HTTPCode_Target_2XX_Count` / `RequestCount` | Edge availability when log metrics are sparse |
| `HTTPCode_Target_5XX_Count` | Customer-visible failures at the load balancer |
| `UnHealthyHostCount` | Capacity / health-check failures before full outage |

---

## Engineering behaviour by error budget state

| Budget state | Signal | Engineering behaviour |
|---|---|---|
| **Healthy** (>50% budget remaining) | Availability ≥ 99.7%, latency p95 < 400 ms | Normal development; deploy during agreed hours; monitor dashboard weekly |
| **Consuming quickly** (<25% budget remaining) | Availability 99.5–99.7% or latency p95 400–500 ms for 24h | Freeze non-critical deploys; daily dashboard review; investigate top `downstream_error` logs and recent ECS deployments |
| **Exhausted** (SLO breached) | Availability < 99.5% over 7 days or sustained p95 > 500 ms | Incident mode: stop feature releases; rollback recent image tags via SSM + `scripts/deploy-iac.sh`; root-cause before next deploy; post-incident update to failure map and runbook |

---

## Evidence checklist (Evidence 01)

- [ ] Screenshot: CloudWatch dashboard `devops-g3-iac-production-readiness` showing all widgets
- [ ] Screenshot: Logs Insights query returning `checkout_completed` events
- [ ] Screenshot: ALB `TargetResponseTime` p95 graph with 500 ms annotation
- [ ] (Optional) 24h of baseline data after deploy before final submission

Save screenshots under `production-readiness/01-reliability-target/screenshots/`.

---

## Known limitations (document in GO-NO-GO)

- ALB metrics aggregate **all** order target group traffic, not only `POST /checkout` (no path-based routing on ALB).
- Log-derived availability only covers failures logged as `downstream_error` on order; payment confirm is best-effort and not counted separately.
- Lab traffic volume is low — SLI graphs may look sparse until load is generated (`scripts/load-test.js` or `scripts/checkout-probe.sh`).
