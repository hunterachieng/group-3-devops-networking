# Failure Map - Customer Checkout

**Critical user journey:** `POST /checkout` via ALB → Order → Inventory → Payment → Payment `/confirm` callback to Order

**Environment:** `devops-g3-iac-*` ECS Fargate, `us-west-1`, account `240462142849`

**Related:** [Reliability target](../01-reliability-target/reliability-target.md) | [Runbook](../04-runbook/runbook.md) | [Incident timeline](../05-incident-timeline/incident-timeline.md)

---

## Checkout path (production)

```
Customer
  → ALB (devops-g3-iac-alb) :80
  → Order ECS (2 tasks, devops-g3-iac-order) :3001
  → Service Connect DNS (inventory:3002)
  → Inventory ECS (1 task, devops-g3-iac-inventory) :3002
  → Service Connect DNS (payment:3003)
  → Payment ECS (1 task, devops-g3-iac-payment) :3003
  → callback POST /confirm → Order :3001
  → response to customer
```

Order health check path: ALB → `GET /health` on order target group (not `/checkout`).

---

## Failure map

| Component | What can fail | How we detect it | What absorbs / tolerates it | What the user experiences |
|---|---|---|---|---|
| **ALB / target group** | Listener misconfig; all order targets unhealthy; path only routes to order | CloudWatch `UnHealthyHostCount`, alarm `devops-g3-iac-pr-unhealthy-order-targets`; target group health tab (`Target.Timeout` vs `Connection refused`) | Multi-AZ ALB; order runs 2 tasks - one unhealthy target may still serve traffic | 502/503 from ALB; checkout unavailable at the edge |
| **ALB / health vs checkout** | Order `/health` passes while `/checkout` fails (downstream broken) - **observed in drill** | Log metric `CheckoutFailure` / `downstream_error`; dashboard checkout availability SLI; alarm `devops-g3-iac-pr-checkout-availability-degraded` on 5xx | Nothing at ALB - health check does not call inventory | Customer sees HTTP 502 with `"outcome":"failure"`; ALB target health stays green |
| **Order ECS service** | Task crash; OOM; bad image deploy | ECS service events; `UnHealthyHostCount`; order logs; deployment circuit breaker rollback | **2 tasks** - second task may absorb one failure; ECS circuit breaker rolls back bad deploys | Intermittent or total checkout failure depending on how many tasks fail |
| **Service Connect / internal DNS** | Namespace drift; SC proxy unreachable; wrong discovery name | Order logs connection errors to `inventory:3002` or `payment:3003`; Envoy errors in task logs; cross-service trace gaps | Retries limited - order uses single `requests.post` with 5s timeout | 502 from order: `"inventory service unavailable"` or payment path never reached |
| **Inventory ECS** | Single task stopped/scaled to 0; crash; deploy failure - **drilled scenario** | ECS `runningCount < desiredCount`; order logs `downstream_error`; checkout availability alarm; dashboard failure spike | **None** - `desired_count = 1`, no HA | Every checkout returns 502 until inventory restored |
| **Payment + confirm callback** | Payment down; charge succeeds but `/confirm` to order fails (best-effort) | Payment/inventory logs; order may still return 200 on checkout while confirm is async | Checkout HTTP response can succeed before confirm; confirm is not counted in availability SLI today | Customer may see success JSON but order state incomplete; ops must correlate by `request_id` |
| **CPU / memory saturation** | Order CPU > 80% sustained; memory pressure; latency SLO burn | Alarm `devops-g3-iac-pr-order-saturation-high`; dashboard CPU/memory; latency alarm `devops-g3-iac-pr-checkout-latency-high` | 2 order tasks share load; ALB round-robin | Slow checkout (p95 > 500 ms); eventual timeouts and 502 under extreme load |
| **Bad deploy (ECS circuit breaker)** | New task fails health checks; bad image tag | ECS deployment events "circuit breaker triggered"; rollback to previous task set; spike in task churn | Circuit breaker auto-rollback; brief blip if one task still healthy | Short checkout errors during deploy window; usually self-heals without manual action |
| **Security group drift** | `alb-sg → order-sg:3001` rule removed - Phase 4 sabotage | Target health `Target.Timeout`; alarm on unhealthy targets; compare Terraform state vs live SG rules | Internal payment→order callback may still work if only ALB rule dropped | Public checkout dead (502/timeout) while internal paths may partially work |

---

## Drill correlation (2026-08-28)

Controlled failure: inventory scaled to `desired-count 0`.

| Expected signal | Observed |
|---|---|
| Order `/health` still 200 | Yes - targets stayed healthy |
| Checkout 502 | Yes - `downstream_error` in logs |
| 5xx ALB metric spike | Yes - 6 then 11 errors/min at 11:42–11:43 UTC |
| Alarm fired | Yes - `devops-g3-iac-pr-checkout-availability-degraded` at 11:46:15 UTC |

Evidence: [dashboard during recovery](../05-incident-timeline/evidence/cloudwatch-dashboard-during-recovery.png)

---

## Gaps to address before production

1. **Detection:** Add synthetic checkout probe (e.g. `scripts/checkout-probe.sh` on a schedule) - ALB `/health` alone is insufficient.
2. **Tolerance:** Increase inventory `desired_count` to 2+ or add auto-scaling on health check failures.
3. **Correctness SLI:** Track payment confirm success separately from checkout HTTP 200.
