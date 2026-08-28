# Production Readiness - GO / NO-GO Decision

**System:** Group 3 checkout pipeline (`devops-g3-iac-*`)  
**Critical journey:** Customer checkout - `POST /checkout` via ALB → Order → Inventory → Payment  
**Region:** `us-west-1` | **Account:** `240462142849`  
**Review date:** 2026-08-28

---

## Decision

## **GO WITH CONDITIONS**

The team can operate this environment responsibly for a **lab / cohort production-readiness demo**, provided the conditions below are tracked and the known gaps are addressed before a real customer-facing launch.

---

## Three strongest pieces of evidence

### 1. Live dashboard shows real SLI impact and recovery

CloudWatch dashboard `devops-g3-iac-production-readiness` captured checkout availability dropping to 0% during the inventory drill and recovering to 100% after mitigation.

- Doc: [01-reliability-target/reliability-target.md](01-reliability-target/reliability-target.md)
- Screenshot: [01-reliability-target/screenshots/dashboard-full.png](01-reliability-target/screenshots/dashboard-full.png)
- Drill: [05-incident-timeline/evidence/cloudwatch-dashboard-during-recovery.png](05-incident-timeline/evidence/cloudwatch-dashboard-during-recovery.png)

### 2. Actionable alerts fired and cleared with notification

Alarm `devops-g3-iac-pr-checkout-availability-degraded` entered **ALARM** at **11:46:15 UTC** when 5xx errors spiked, sent SNS → Lambda → Slack `#group-3-alerts`, and returned **OK** at **12:00:15 UTC** after recovery.

- Doc: [03-alerts/alert-definitions.md](03-alerts/alert-definitions.md)
- Proof: [04-runbook/test-evidence/alarm-history.txt](04-runbook/test-evidence/alarm-history.txt)
- Screenshots: [03-alerts/screenshots/alarms-all-ok.png](03-alerts/screenshots/alarms-all-ok.png)

### 3. Runbook tested - customer journey restored, not just containers

Controlled drill (inventory scale-to-zero) was diagnosed via order logs and ECS, recovered with documented steps, and validated with successful checkout (`"outcome":"success"`).

- Runbook: [04-runbook/runbook.md](04-runbook/runbook.md)
- Timeline: [05-incident-timeline/incident-timeline.md](05-incident-timeline/incident-timeline.md)
- Validation: [04-runbook/test-evidence/checkout-success.json](04-runbook/test-evidence/checkout-success.json)

---

## Conditions / known risks

| Risk | Severity | Mitigation plan |
|---|---|---|
| **HTTP only** - no TLS on ALB | High for real prod | Add ACM certificate + HTTPS listener before external launch |
| **Inventory single-task** (`desired_count = 1`) | High | Scale to 2+ tasks; add auto-scaling |
| **ALB `/health` ≠ checkout health** | Medium | Synthetic checkout probe; alert on log-derived failures |
| **Payment → Order confirm is best-effort** | Medium | Add confirm success to correctness SLI |
| **Slack via Lambda webhook** (Chatbot blocked by SSO) | Low for lab | Acceptable for cohort; consider Chatbot if SSO policy changes |
| **Manual recovery** for inventory outage | Medium | Document runbook (done); automate for prod |
| **Low lab traffic** - sparse SLI graphs without probe | Low | Run `scripts/checkout-probe.sh` or load test for baseline data |

---

## Evidence pack completeness

| # | Item | Status |
|---|---|---|
| 01 | Reliability target | ✅ |
| 02 | Failure map | ✅ |
| 03 | Actionable alerts | ✅ |
| 04 | Runbook + test evidence | ✅ |
| 05 | Incident timeline | ✅ |
| - | GO-NO-GO (this document) | ✅ |

---

## What would change this to **GO** (unconditional)

1. HTTPS on the ALB
2. Inventory HA (≥ 2 tasks) with auto-scaling
3. Scheduled synthetic checkout probe with alert
4. Payment confirm tracked in correctness SLI

## What would change this to **NO-GO**

- Dashboard or alarms not deployed / not receiving data
- No defined SLO or error budget
- Alerts with no runbook or untested recovery path
- Checkout journey never validated after incident recovery

---

## Sign-off

| Role | Name | Date |
|---|---|---|
| Operator / submitter | Rachel Minage | 2026-08-28 |
| Infrastructure (01, 03) | Hunter | 2026-08-28 |
