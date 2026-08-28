# Runbook - Inventory Unavailable (Checkout 502)

**Scenario:** Inventory service down or scaled to zero → Order cannot reach `inventory:3002` → checkout returns HTTP 502.

**Maps to alarm:** `devops-g3-iac-pr-checkout-availability-degraded`

**Environment:** `devops-g3-iac-*` | Region: `us-west-1` | Account: `240462142849`

**Prerequisites:**

```bash
aws login --profile group3
export AWS_PROFILE=group3
export AWS_REGION=us-west-1
```

---

## 1. Trigger

Respond when **any** of these occur:

| Signal | Where |
|---|---|
| CloudWatch alarm `devops-g3-iac-pr-checkout-availability-degraded` in **ALARM** | CloudWatch → Alarms |
| Slack message in `#group-3-alerts` with `[ALARM]` for checkout availability | Slack |
| Customer or probe report: checkout HTTP 502, `"outcome":"failure"` | `./scripts/checkout-probe.sh` or manual curl |

**Alarm description (WHAT / WHY / WHERE):**

- **WHAT:** Order target group returning HTTP 5xx through the ALB
- **WHY:** Customers cannot complete checkout - burns checkout availability SLO
- **WHERE:** (1) ALB target health, (2) order ECS events, (3) order logs `downstream_error`, (4) inventory/payment task health

---

## 2. Verify impact

Confirm the **customer journey** is broken, not just a container status.

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names devops-g3-iac-alb \
  --query 'LoadBalancers[0].DNSName' --output text --region us-west-1)

curl -s -w "\nHTTP_CODE=%{http_code}\n" -X POST "http://${ALB_DNS}/checkout" \
  -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}'
```

**Expected during incident:**

- HTTP **502**
- JSON contains `"outcome":"failure"` and `"error":"inventory service unavailable"`

**Optional - check ALB health (may still be green):**

```bash
curl -s "http://${ALB_DNS}/health"
# May return 200 even while checkout fails - do not use /health alone as recovery proof
```

---

## 3. Diagnose

Work top-down: edge → order → inventory.

### 3.1 ECS - inventory task count

```bash
aws ecs describe-services --cluster devops-g3-iac-cluster \
  --services devops-g3-iac-inventory \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,events:events[0:3]}' \
  --region us-west-1
```

**Look for:** `runningCount: 0` or `running < desired`.

### 3.2 Order logs - downstream errors

CloudWatch → Logs → `/ecs/devops-g3-iac/order` → Logs Insights:

```sql
fields @timestamp, event, request_id, order_id, outcome, target
| filter event = "downstream_error"
| sort @timestamp desc
| limit 20
```

**Look for:** `inventory unreachable` and `target: http://inventory:3002`.

### 3.3 Dashboard - SLI impact

CloudWatch → Dashboards → **`devops-g3-iac-production-readiness`**

Check widgets:

- Checkout availability SLI (drops toward 0%)
- Checkout outcomes - failure spike
- ALB 5xx count

Screenshot reference: [test-evidence](../04-runbook/test-evidence/) and [timeline evidence](../05-incident-timeline/evidence/).

### 3.4 Rule out other causes (if inventory looks healthy)

| Check | Command / location |
|---|---|
| Payment down | ECS `devops-g3-iac-payment` running count; inventory logs for payment errors |
| Order saturated | Alarm `devops-g3-iac-pr-order-saturation-high`; dashboard CPU panel |
| SG drift on order | Target health reason `Target.Timeout` - see [PHASE4-ORDER.md](../../docs/PHASE4-ORDER.md) |
| Bad deploy | ECS service events - circuit breaker rollback |

---

## 4. Mitigate

**If inventory is scaled to 0 or tasks are not running:**

```bash
aws ecs update-service --cluster devops-g3-iac-cluster \
  --service devops-g3-iac-inventory \
  --desired-count 1 \
  --region us-west-1
```

**If task exists but unhealthy:**

1. ECS → `devops-g3-iac-inventory` → Tasks → check stopped reason
2. CloudWatch Logs → `/ecs/devops-g3-iac/inventory` for crash/OOM
3. If bad deploy: note image tag; rollback via SSM parameter + `scripts/deploy-iac.sh` (see [REDEPLOY-RUNBOOK.md](../../docs/REDEPLOY-RUNBOOK.md))

Do **not** declare recovery when only `runningCount >= 1` - proceed to Validate.

---

## 5. Recover

Wait for:

1. Inventory task **RUNNING**
2. Service Connect registration healthy (inventory reachable from order)
3. ALB 5xx rate returning to zero under probe traffic

Monitor deployment:

```bash
aws ecs wait services-stable --cluster devops-g3-iac-cluster \
  --services devops-g3-iac-inventory --region us-west-1
```

Watch alarm return to **OK** (may take ~2–4 minutes after 5xx stops).

---

## 6. Validate

**Required:** Prove successful checkout - not just healthy containers.

```bash
curl -s -X POST "http://${ALB_DNS}/checkout" \
  -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}'
```

**Pass criteria:**

- HTTP **200**
- `"outcome":"success"`
- `"order_id":"ORD-..."` present

**Secondary checks:**

```bash
# Alarm cleared
aws cloudwatch describe-alarms --alarm-names devops-g3-iac-pr-checkout-availability-degraded \
  --query 'MetricAlarms[0].StateValue' --output text --region us-west-1
# Expected: OK

# Log proof
# Logs Insights on /ecs/devops-g3-iac/order - recent checkout_completed events
```

**Drill validation (2026-08-28):** Post-recovery checkout succeeded (`ORD-E8DEB388` per drill notes; live re-check also passed).

---

## 7. Escalate

| Situation | Action |
|---|---|
| Inventory won't start (CannotPullContainerError, insufficient CPU) | Check ECS events, ECR image tag in Terraform tfvars, platform admin |
| Inventory running but checkout still 502 | Check Service Connect, SG rules order→inventory:3002, inventory `/ready` |
| Order targets unhealthy (`Target.Timeout`) | SG drift - compare Terraform vs live rules; see Phase 4 scar log |
| Alarm won't clear after recovery | Confirm probe traffic stopped producing 5xx; check 2×60s evaluation window |
| Payment path failing after inventory fixed | Escalate to payment owner; filter logs across inventory + payment by `request_id` |

**Notification path:** CloudWatch → SNS `devops-g3-iac-production-readiness-alerts` → Lambda `devops-g3-iac-slack-notifier` → `#group-3-alerts`

---

## Test evidence

This runbook was validated against the controlled drill on **2026-08-28** (inventory scale-to-zero).

| Artifact | Location |
|---|---|
| Alarm state history (ALARM → OK) | [test-evidence/alarm-history.txt](test-evidence/alarm-history.txt) |
| Probe output during failure (502s) | [test-evidence/probe-output.txt](test-evidence/probe-output.txt) |
| Post-recovery checkout JSON | [test-evidence/checkout-success.json](test-evidence/checkout-success.json) |
| Alarm screenshots | [../03-alerts/screenshots/](../03-alerts/screenshots/) |
| Timeline screenshots | [../05-incident-timeline/evidence/](../05-incident-timeline/evidence/) |
