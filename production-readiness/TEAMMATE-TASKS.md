# Production Readiness — Teammate Task Split

**Done in this branch (Hunter):** Phase 1 (reliability target) + Phase 3 (Terraform alerts & dashboard)

**Your team submits:** one `production-readiness/` folder with all five evidence items + `GO-NO-GO.md`

---

## Quick status

| Evidence | Owner | Status | Deliverable |
|---|---|---|---|
| 01 Reliability target | Hunter | **Done** — review & add screenshots | `01-reliability-target/reliability-target.md` |
| 02 Failure map | **Assign** | Not started | `02-failure-map/failure-map.md` |
| 03 Actionable alerts | Hunter | **Done** — apply Terraform & add screenshots | `03-alerts/alert-definitions.md` + live alarms |
| 04 Runbook | **Assign** | Not started | `04-runbook/runbook.md` + test evidence |
| 05 Incident timeline | **Assign** | Not started | `05-incident-timeline/incident-timeline.md` |
| GO-NO-GO | **Assign (lead)** | Not started | `GO-NO-GO.md` |

---

## Before anyone starts

1. **Apply observability Terraform** (whoever has AWS creds):

```bash
cd infra/environments/lab
# optional: echo 'alert_email = "team@example.com"' >> terraform.tfvars
terraform plan
terraform apply
```

2. **Confirm stack is healthy:**

```bash
./scripts/deploy-iac.sh   # if needed
ALB_DNS=$(terraform output -raw alb_dns_name)
curl -s "http://${ALB_DNS}/health"
curl -s -X POST "http://${ALB_DNS}/checkout" \
  -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}'
```

3. **Open the dashboard:** CloudWatch → `devops-g3-iac-production-readiness`

---

## Task A — Failure map (Evidence 02)

**Suggested owner:** Person who knows networking / Phase 4 sabotage work  
**Time:** ~2–3 hours  
**Depends on:** Nothing (can start immediately)

### Deliverable

Create `production-readiness/02-failure-map/failure-map.md` with **≥5 components** on the checkout path.

### Required table columns (per component)

1. What can fail  
2. How will we detect it  
3. What absorbs/tolerates the failure  
4. What does the user experience  

### Must include components from both app and platform

Use this checklist — cover at least five:

- [ ] ALB / target group / health checks  
- [ ] Order ECS service (tasks, deploy, OOM)  
- [ ] Service Connect / internal DNS  
- [ ] Inventory ECS service (single task — no HA)  
- [ ] Payment ECS service + best-effort confirm callback  
- [ ] CPU/memory saturation  
- [ ] Bad deployment (circuit breaker rollback)  
- [ ] Security group drift (`Target.Timeout` — see `docs/PHASE4-ORDER.md`)

### References

- `docs/PHASE4-ORDER.md` — sabotage round, scar log format  
- `docs/architecture.md` — service flow  
- `production-readiness/01-reliability-target/reliability-target.md` — SLI context  

### Optional

- Mermaid or draw.io diagram exported to `02-failure-map/architecture-diagram.png`

### Done when

Another engineer can read the map and predict what a customer sees when inventory dies vs when the ALB loses SG access to order.

---

## Task B — Incident runbook (Evidence 04)

**Suggested owner:** Person who will operate the drill  
**Time:** ~3–4 hours (includes one live test)  
**Depends on:** Task A helpful but not blocking; alerts must be applied (Phase 3)

### Deliverable

`production-readiness/04-runbook/runbook.md`  
`production-readiness/04-runbook/test-evidence/` — CLI output, log snippets, screenshots

### Recommended scenario

**Inventory unavailable → checkout failing**

Why: single inventory task, clear customer impact, straightforward recovery, maps to Alert 1.

### Required sections

```
Trigger → Verify impact → Diagnose → Mitigate → Recover → Validate → Escalate
```

### Validate step (critical)

Must prove **successful checkout**, not just "inventory task RUNNING":

```bash
curl -s -X POST "http://${ALB_DNS}/checkout" \
  -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}'
```

Also grep logs for `checkout_completed` with the returned `request_id`.

### Injection command (for test)

```bash
aws ecs update-service --cluster devops-g3-iac-cluster \
  --service devops-g3-iac-inventory --desired-count 0 --region us-west-1
```

Recovery:

```bash
aws ecs update-service --cluster devops-g3-iac-cluster \
  --service devops-g3-iac-inventory --desired-count 1 --region us-west-1
```

Use `./scripts/checkout-probe.sh` during the outage to generate failing requests.

### Done when

Someone **other than the author** can follow the runbook cold, or you have a recorded dry-run with timestamps in `test-evidence/`.

---

## Task C — Incident timeline (Evidence 05)

**Suggested owner:** Person who did NOT write the runbook (fresh eyes)  
**Time:** ~2–3 hours  
**Depends on:** Task B runbook exists; alerts applied

### Deliverable

`production-readiness/05-incident-timeline/incident-timeline.md`  
`production-readiness/05-incident-timeline/evidence/` — logs, alarm history screenshots, probe output

### Execute one controlled failure

Pick one (inventory scale-to-zero recommended):

| Failure | Command |
|---|---|
| Kill inventory | `aws ecs update-service ... inventory --desired-count 0` |
| Stop payment task | `aws ecs list-tasks` + `aws ecs stop-task` |
| Bad deploy | Push broken SHA (Gate 3B rollback) — harder, optional |

### Capture timeline

| Timestamp (UTC) | Event |
|---|---|
| T0 | Failure injected |
| T1 | First signal (failed checkout / log / metric) |
| T2 | Alert fires (CloudWatch ALARM) |
| T3 | Diagnosis complete |
| T4 | Mitigation applied |
| T5 | Recovery complete |
| T6 | SLI restored (successful checkout) |

**Calculate:**

- **TTD** = T2 − T0 (time until alert pages an operator)  
- **TTR** = T6 − T0 (time until customer journey works again)

### Required gap analysis

Document **one detection gap** and **one recovery gap**, e.g.:

- **Detection gap:** Order ALB health checks `/health` only — checkout can fail while targets stay healthy until 5xx accumulate under probe traffic.  
- **Recovery gap:** Manual `update-service` required; no auto-scaling on inventory.

### Tools

```bash
# Continuous probe with timestamps
./scripts/checkout-probe.sh --interval 5

# Alarm history
aws cloudwatch describe-alarm-history \
  --alarm-name devops-g3-iac-pr-checkout-availability-degraded \
  --region us-west-1
```

### Rule

**Capture evidence before repair** (same discipline as Phase 4).

### Done when

Timeline has real timestamps, TTD/TTR numbers, and two honest gaps with proposed fixes.

---

## Task D — GO-NO-GO decision (final)

**Suggested owner:** Team lead / whoever submits  
**Time:** ~1 hour  
**Depends on:** Tasks A–C complete; screenshots added to 01 and 03

### Deliverable

`production-readiness/GO-NO-GO.md`

### Template

```markdown
# Production Readiness Decision

**Decision:** GO | GO WITH CONDITIONS | NO-GO

## Top 3 pieces of evidence
1. ...
2. ...
3. ...

## Conditions (if GO WITH CONDITIONS)
- ...

## Known risks accepted
- HTTP only (no TLS)
- Inventory single-task
- Payment confirm best-effort
```

### Decision guide

| Verdict | When |
|---|---|
| **GO** | All alarms fired in drill; runbook validated; SLO dashboard has data; failure map complete |
| **GO WITH CONDITIONS** | Telemetry works but known gaps documented with remediation plan |
| **NO-GO** | Docs only, alarms never tested, or no runbook validation |

---

## Task E — Screenshots (shared, small)

**Owner:** Anyone with AWS console access  
**Add to:**

- `01-reliability-target/screenshots/` — dashboard, Logs Insights, p95 latency  
- `03-alerts/screenshots/` — alarms OK + one ALARM state during drill  

---

## Suggested assignment (Group 3, 4 people)

| Person | Tasks |
|---|---|
| Hunter | 01 + 03 (done); support drill |
| Teammate 1 | Task A — failure map |
| Teammate 2 | Task B — runbook + test |
| Teammate 3 | Task C — incident timeline |
| Lead (rotate) | Task D — GO-NO-GO + Task E screenshots |

If only 3 people: combine Task E into whoever runs the drill (Task C).

---

## Submission checklist (whole team)

```
production-readiness/
├── 01-reliability-target/reliability-target.md + screenshots/
├── 02-failure-map/failure-map.md
├── 03-alerts/alert-definitions.md + screenshots/
├── 04-runbook/runbook.md + test-evidence/
├── 05-incident-timeline/incident-timeline.md + evidence/
├── GO-NO-GO.md
└── TEAMMATE-TASKS.md          (optional — can remove before submit)
```

**Standard reminder:** Polished docs without working telemetry = NO-GO. Your alarms must fire in a real drill.
