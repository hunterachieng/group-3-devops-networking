# Phase 4 — Operations Evidence (compiled)

**Group:** group-3 | **Region:** us-west-1 | **Cluster:** devops-g3-cluster
**Account:** 827478161993 | **ALB:** devops-g3-alb | **Target group:** devops-g3-order-tg
**Compiled:** 2026-07-23 | **Status: COMPLETE** (optional round-out items noted in §6)

Service mapping: A = order (3001), B = inventory (3002), C = payment (3003).

## Ownership
| Member | Role | Phase 4 status |
|---|---|---|
| Hunter | order (A) | 4.1 ✅ · sabotage S1 ✅ · kill R1 ✅ |
| Joyce | inventory (B) | 4.1 ✅ · sabotage S5 ✅ (re-run, clean capture) · kill ✅ (86s outage) · strong scar log |
| Wairimu | payment (C) | 4.1 ✅ · sabotage S4 ✅ (OOM) · teammate investigation 4.2b ✅ · kill ✅ (115s outage) |
| Lwam | platform | canonical 4.1 trace ✅ · sabotage S2 ✅ · platform path ✅ · kill R2 ✅ |
| Minage | platform | 4.1 ✅ · sabotage S3 ✅ · kill R3 ✅ |

---

## 1. Exercise 4.1 — Trace one request

**Canonical request** (raw order+inventory+payment logs on one ID, Lwam's PDF §4.1):
`request_id = e89df09b-2560-4fcd-861d-77809c760e6b`, `order_id = ORD-768139EF`, `200 OK`.
Same ID in all three log groups: order `checkout_received → reserving_inventory →
order_confirmed → checkout_completed`; inventory `reserve_received → stock_reserved →
charging_payment → reserve_completed`; payment `charge_received → payment_captured →
confirming_order → charge_completed confirm=sent`.

**Own-service confirmations:** Joyce (`inv-trace-1784741677`) inventory B-hop log;
Wairimu (`phase4-payment-1784750363`, trace `8152ab7f…`) payment B->C plus the
`payment → order` callback landing as `order_confirmed` on `ORD-CB5EA356`.

### Per-hop table
| Hop | Resource that permits it | Port | Evidence | Failure symptom if broken |
|---|---|---|---|---|
| DNS | ALB public name | 53/80 | dig -> 52.52.12.171, 18.144.109.142 | NXDOMAIN / timeout |
| ALB listener | HTTP:80 listener; alb-sg inbound 80 from 0.0.0.0/0 | 80 | listener forwards to order-tg; curl 200 | connection refused at :80 |
| Target group | order-tg; alb-sg -> order-sg:3001; targets healthy | 3001 | 2 healthy targets | 502/503 |
| Service A (order) | order task RUNNING | app | order log, same request_id | 5xx |
| SC A->B | namespace group3.internal; inventory-sg inbound 3002 from order-sg | 3002 | inventory log, same request_id | unresolved / refused |
| Service B (inventory) | inventory task RUNNING | app | inventory log, same request_id | 5xx |
| SC B->C | payment-sg inbound 3003 from inventory-sg | 3003 | payment log, same request_id | refused / unresolved |
| Service C (payment) | payment task RUNNING | app | payment log, same request_id | 5xx |
| Callback C->A | order-sg inbound 3001 from payment-sg (deliberate edge) | 3001 | order `order_confirmed`, same request_id | refused (best-effort; charge still ok) |

**Status: ✅** one request ID across all three services; callback proven.

### Comparison to Phase 1 predictions
| Prediction | Predicted symptom | Confirmed |
|---|---|---|
| Execution role missing ECR-pull | task never RUNNING, CannotPullContainerError | not observed (tasks RUNNING) |
| order bound to 127.0.0.1 | target unhealthy, 502/503 | not observed (bound 0.0.0.0, healthy) |
| Missing alb-sg -> order-sg rule | target unhealthy, timeouts | reproduced deliberately (Hunter, S1) |

---

## 2. Exercise 4.2 — Sabotage round

Injections by all three service owners plus both platform owners, and one documented
service-owner teammate investigation (Wairimu, 4.2b).

### Injected faults
| # | Owner | Fault | Key diagnostic signal | Status |
|---|---|---|---|---|
| S1 | Hunter (order) | Revoked `alb-sg -> order-sg:3001` SG rule | `Target.Timeout` (drop) vs `Connection refused` (app down) | ✅ |
| S2 | Lwam (platform) | Wrong health-check path `/healthz` (order TG) | `Target.ResponseCodeMismatch [404]` | ✅ |
| S3 | Minage (platform) | Deregistered one healthy target | draining while ECS desired=2/running=2, `/health` 200 | ✅ |
| S4 | Wairimu (payment) | Container memory 32 MB (OOM) | `exitCode 137`, `OutOfMemoryError`; 128 MB survived (dose-response) | ✅ |
| S5 | Joyce (inventory) | Wrong health-check path `/healthz` (ECS health check) | PRIMARY deployment stuck `running=0`; `failed container health checks` | ✅ |

> S2 and S5 are the same fault class on two surfaces (ALB target group vs ECS container
> health check). Kept as "one fault, two detection surfaces."

### Selected scar entries
**S1 — Hunter (SG revoke, Demo 8 candidate):** app healthy throughout; `Target.Timeout`
(silent drop) vs `Connection refused` (app down) redirected the investigation from app
to network. Repair: re-authorize ingress. Prevention: SG rules as IaC + `UnHealthyHostCount` alarm.

**S4 — Wairimu (OOM):** 32 MB container limit -> `exitCode 137` + `OutOfMemoryError`; the
128 MB first attempt survived, so the two attempts bracket the real idle ceiling
(genuine dose-response finding). Prevention: bisect between known-safe/known-broken; don't
mistake ECS's retry loop for recovery.

**S5 — Joyce (inventory health path):** with `minimumHealthyPercent=100`, ECS starts the
replacement before draining the old task, so a bad *deployment* has **zero customer
impact** (checkout 200 throughout) while the broken revision cycles. The decisive artifact
was `describe-services deployments` (PRIMARY `:7` running=0 IN_PROGRESS vs ACTIVE `:1`
still serving), not a single `describe-tasks` sample. Rollback restored and verified
`{enable:true, rollback:true}`.

### 4.2b — Teammate investigation (Wairimu)
Symptom-first, service unknown. Ruled out order (2/2 healthy, clean rolling deploy 35 min
before the symptom), then traced a real ~45s customer-facing incident to a confirmed ~77s
**Inventory** task-replacement gap, timestamps matching. Demonstrates diagnosing another
owner's service from evidence without console takeover.

**Status: ✅** Five injected faults; one documented service-owner teammate investigation.

---

## 3. Exercise 4.3 — Kill a task

### Order (desired count 2) — zero user impact, three runs
| Run | Owner | Victim | Recovery signal | Failed / non-200 |
|---|---|---|---|---|
| R1 | Hunter | 172.31.4.149 | new target 172.31.12.194 healthy (~39.4s infra) | 0 / 0 |
| R2 | Lwam | task 5f95f297… | running 1 -> 2; new target 172.31.24.36 healthy | non-200 grep empty |
| R3 | Minage | task 1b9df7bc… | new target 172.31.27.92 healthy 18:34:41Z | 0 / 0 (90 reqs) |

### Single-task services (desired count 1) — real outage
| Service | Owner | Result |
|---|---|---|
| inventory | Joyce | 86s failure window, 52 failed `/checkout` (502); 21s SIGTERM graceful drain; ~9s flap before SC settled; conservative recovery 109s |
| payment | Wairimu | 115s outage, 111/356 requests failed (all 503, no partial degradation); HTTP-level and ECS-level timelines cross-checked and consistent |

Order's zero-impact runs plus the two measured single-task outages are the concrete
argument for replica count >= 2 for any synchronously-depended-on service.

**Status: ✅**

---

## 4. Consolidated scar log (feeds 12% band + Demo 8)

**Joyce's inventory scar log is the strongest body** (continues Phase 2 numbering):
scar 7 (log-tail window too short), scar 8 (wrong fault: image tag with no image),
scar 9 (bare family name -> latest/stale revision), scar 10 (evidence dir deleted),
scar 11 (measured an outage the kill did not cause — causation vs correlation),
scar 12 (resolved: capture the deployment view + all tasks, not `taskArns[0]`).

**Platform / order / payment:** S1 (SG revoke: `Target.Timeout` vs `Connection refused`),
S2 (health-path 404), S3 (target deregister), S4 (OOM dose-response). Gotcha: ECS Exec
fails on tasks started before exec was enabled; resolve fresh task ARNs after a redeploy.

**Demo 8 "best scar" options:** S1 (clearest single app-vs-network lesson) · Joyce scar 11
(don't write up an outage you can't prove you caused) · Joyce S5 (deployment safety vs
single-replica availability are different properties).

---

## 5. Demo readiness
| Demo | Requirement | Covered by | Status |
|---|---|---|---|
| Demo 2 (end-to-end trace) | same correlation ID in all three | §1 canonical trace | ✅ |
| Demo 4 (failure diagnosis) | diagnose an injected fault from evidence | S1-S5 + Wairimu 4.2b | ✅ |
| Demo 5 (availability) | stop a task, show recovery | order R1-R3 + inventory + payment outages | ✅ |
| Demo 8 (best scar) | most instructive scar | S1 / Joyce scar 11 / S5 | ✅ |

---
