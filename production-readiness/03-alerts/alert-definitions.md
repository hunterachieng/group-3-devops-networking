# Actionable Alerts - Production Readiness

**Infrastructure:** Terraform module `infra/modules/observability/`  
**SNS topic:** `devops-g3-iac-production-readiness-alerts`  
**Runbook:** `production-readiness/04-runbook/runbook.md` (teammate-owned - link alarms here after runbook is written)

---

## Deploy and subscribe

```bash
cd infra/environments/lab

# Optional: GitHub repo Variables for CI deploy (recommended)
# SLACK_WEBHOOK_URL  → Lambda → Slack #group-3-alerts (no AWS Chatbot OAuth needed)
# ALERT_EMAIL        → optional email alongside Slack
# SLACK_TEAM_ID + SLACK_CHANNEL_ID → AWS Chatbot (only if console OAuth works)

terraform plan
terraform apply

# Verify outputs
terraform output production_readiness_dashboard_name
terraform output production_readiness_alarm_names
terraform output production_readiness_sns_topic_arn
terraform output production_readiness_slack_lambda_enabled
```

**Slack (recommended):** Set GitHub variable `SLACK_WEBHOOK_URL` to your Incoming Webhook for `#group-3-alerts`. CI deploys a Lambda that posts alarm notifications - no AWS Chatbot console access required.

**Notification path:**

```
CloudWatch Alarm → SNS (devops-g3-iac-production-readiness-alerts)
                      ├→ email (optional, ALERT_EMAIL)
                      └→ Lambda → Slack Incoming Webhook → #group-3-alerts
```

**Dashboard URL:** CloudWatch → Dashboards → `devops-g3-iac-production-readiness`

---

## Alert summary

| # | Alarm name | Category | Signal | Threshold | Evaluation |
|---|---|---|---|---|---|
| 1 | `devops-g3-iac-pr-checkout-availability-degraded` | Availability | ALB `HTTPCode_Target_5XX_Count` | ≥ 1 | 2 × 60s periods |
| 2 | `devops-g3-iac-pr-checkout-latency-high` | Latency | ALB `TargetResponseTime` p95 | > 0.5 s | 5 × 60s periods |
| 3 | `devops-g3-iac-pr-order-saturation-high` | Saturation | Container Insights `CpuUtilized` | > 80% | 10 × 60s periods |
| 4 | `devops-g3-iac-pr-unhealthy-order-targets` | Availability | ALB `UnHealthyHostCount` | ≥ 1 | 2 × 60s periods |

Alerts 1–3 satisfy the challenge requirement (availability, latency, saturation). Alert 4 catches health-check / SG drift failures before full 5xx spikes.

---

## Alert 1: Checkout availability degraded

| Field | Detail |
|---|---|
| **What is wrong?** | The order target group is returning HTTP 5xx responses to clients via the ALB. |
| **Why does it matter?** | Customers cannot complete checkout - direct SLO burn on checkout availability. |
| **Where to investigate first?** | (1) ALB → Target groups → `devops-g3-iac-order-tg` health, (2) ECS → `devops-g3-iac-order` service events, (3) CloudWatch Logs `/ecs/devops-g3-iac/order` filter `downstream_error`, (4) inventory/payment task status. |
| **Likely causes** | Inventory or payment down; order crash; bad deployment; downstream timeout. |
| **Operator action** | Follow runbook § Verify → Diagnose → Mitigate. Do not ignore if only `/health` passes - check `/checkout`. |

**Prove it fires (lab drill):**

```bash
aws ecs update-service --cluster devops-g3-iac-cluster \
  --service devops-g3-iac-inventory --desired-count 0 --region us-west-1

# Generate traffic
./scripts/checkout-probe.sh

# Expect 502 responses → 5xx count increases → alarm within ~2 min
```

---

## Alert 2: Checkout latency high

| Field | Detail |
|---|---|
| **What is wrong?** | p95 ALB target response time exceeds 500 ms for a sustained period. |
| **Why does it matter?** | Checkout latency SLO at risk; users experience slow purchases and timeouts. |
| **Where to investigate first?** | (1) Dashboard latency panel, (2) order CPU/memory on dashboard, (3) logs by `request_id` for slow hops, (4) recent deploys / task restarts. |
| **Likely causes** | CPU saturation; slow inventory/payment; network issues; load test in progress. |
| **Operator action** | Check saturation alert; scale order tasks or increase CPU if legitimate load; rollback if correlated with deploy. |

**Prove it fires (lab drill):** Run k6 stress scenario or temporarily enable `ENABLE_FAILURE_ENDPOINTS` + `/slow` on order (lab only - never in prod).

---

## Alert 3: Order saturation high

| Field | Detail |
|---|---|
| **What is wrong?** | Order service CPU utilization above 80% for 10 consecutive minutes. |
| **Why does it matter?** | Saturation precedes timeouts and cascading checkout failures. |
| **Where to investigate first?** | (1) ECS service `devops-g3-iac-order` → Metrics, (2) ALB request rate, (3) task count vs desired, (4) memory utilization on same dashboard panel. |
| **Likely causes** | Traffic spike; insufficient task CPU; too few tasks (desired_count=2 may be insufficient under stress). |
| **Operator action** | Increase desired count or task CPU in Terraform; investigate abusive traffic; coordinate with latency alert. |

**Prove it fires (lab drill):** `./scripts/load-test.js` stress scenario against ALB DNS.

---

## Alert 4: Unhealthy order targets (supplementary)

| Field | Detail |
|---|---|
| **What is wrong?** | One or more order tasks fail ALB health checks. |
| **Why does it matter?** | Reduced or zero checkout capacity at the edge; may precede 5xx for customers. |
| **Where to investigate first?** | (1) Target group health tab - note `Target.Timeout` vs `Connection refused`, (2) order ECS tasks, (3) SG rule `alb-sg → order-sg:3001`, (4) order container logs. |
| **Likely causes** | SG drift (see Phase 4 scar log); task crash; deployment in progress; bind/port misconfiguration. |
| **Operator action** | If `Target.Timeout`: check security groups. If `Connection refused`: check app/process. |

**Diagnostic heuristic (from Phase 4):** `Target.Timeout` = network/SG block; `Connection refused` = app down.

---

## Alerts we intentionally do not page on

| Condition | Reason |
|---|---|
| Single ECS task recycle during deploy | ECS circuit breaker handles rollback; self-healing |
| `/health` flapping for < 2 min during rollout | Expected; ALB grace period absorbs |
| Zero request volume (no metric data) | `treat_missing_data = notBreaching` - no human action |
| Inventory `/ready` false while ALB `/health` on order still 200 | Covered by checkout failure logs and 5xx alarm under traffic |

---

## Evidence checklist (Evidence 03)

- [ ] Screenshot: All four alarms in CloudWatch Alarms list (OK state)
- [ ] Screenshot: At least one alarm in **ALARM** state during a drill
- [ ] Screenshot: SNS topic with subscription (if email configured)
- [ ] Screenshot: Dashboard showing the signal that triggered the alarm

Save under `production-readiness/03-alerts/screenshots/`.
