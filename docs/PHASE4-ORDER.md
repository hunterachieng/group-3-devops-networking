# Phase 4 — Prove It Operates (order service)

**Owner:** Hunter (order) | **Group:** group-3 | **Region:** us-west-1 | **Cluster:** devops-g3-cluster
**Date:** 2026-07-22

Phase 4 feeds two graded bands — **scar log & evidence quality** and **sabotage
diagnosis & task recovery** — and rehearses Demos 2, 4, 5, 8. Rule for the whole
phase: **evidence beats intuition, no repair before evidence is captured.**

All raw output referenced below is saved under `phase4-evidence/`.

---

## 4.1 Trace one request (Demo 2)

One `POST /checkout` fired through the ALB with a client-supplied correlation ID,
confirmed present in **all three** services' logs.

- Correlation ID: `phase4-trace-1784738157`
- OpenTelemetry trace ID: `b6986d248e97b3a72d027b42b5ed47bb` (identical across all 3)
- Order ID: `ORD-FDEB3508`
- Result: `HTTP/1.1 200 OK`, `server: envoy` (Service Connect), checkout completed in **87.3 ms**

### Per-hop evidence

| Hop | Resource that permits it | Port | Evidence it occurred (`phase4-evidence/4.1-*`) |
|---|---|---|---|
| DNS / ALB listener | Public ALB DNS + HTTP:80 listener, alb-sg inbound 80 from 0.0.0.0/0 | 80 | `4.1-checkout-response.txt`: `HTTP/1.1 200 OK`, `server: envoy` |
| Target group | devops-g3-order-tg, target healthy, alb-sg → order-sg:3001 | 3001 | `4.1-target-health.txt` healthy; order log `checkout_received` 16:36:13.259 |
| Service A (order) | order task RUNNING | app | order log `reserving_inventory` → `target: http://inventory:3002` |
| SC A→B | namespace group3.internal + inventory-sg inbound 3002 from order-sg | 3002 | inventory log `reserve_received`, same request ID, 16:36:13.270 |
| Service B (inventory) | inventory task RUNNING | app | inventory `stock_reserved` → `charging_payment` |
| SC B→C | payment-sg inbound 3003 from inventory-sg | 3003 | payment log `charge_received`, same request ID, 16:36:13.275 |
| Service C (payment) | payment task RUNNING | app | payment `payment_captured` → `confirming_order → http://order:3001` |
| Callback C→A | order-sg inbound 3001 from payment-sg | 3001 | order log `order_confirmed`, same request + order ID, 16:36:13.331 |

### Comparison to Phase 1 predictions

| Phase 1 prediction | Predicted symptom | Confirmed by this phase |
|---|---|---|
| Execution role missing ECR-pull | task never RUNNING, `CannotPullContainerError` | Not observed — task RUNNING, image pulled |
| order bound to 127.0.0.1 | target unhealthy, 502/503 | Not observed — bound 0.0.0.0, targets healthy |
| Missing alb-sg → order-sg rule | target unhealthy, timeouts | **Reproduced deliberately in 4.2** (see below) |

**Done:** same request ID in all three services; trace ID identical across all
three; full A→B→C→callback→A round trip; Phase 1 predictions revisited.

---

## 4.2 Sabotage round — order (blocking SG rule)

**Injected fault (revealed only after diagnosis):** revoked the security-group
ingress rule `alb-sg (sg-015626e66541ef10d) → order-sg:3001`, cutting the ALB
off from the order tasks. Evidence captured **before** any repair.

### Scar-log entry

| Field | Entry |
|---|---|
| **Symptom** | All requests through the ALB failed (`4.2-order/04-traffic-during-fault.txt`: `status=000` for the whole window); ALB targets flipped to `unhealthy`, reason `Target.Timeout` — "Request timed out" (`05-fault-health.txt`). |
| **First hypothesis** | Order tasks crashed or stopped (app-level outage). |
| **Evidence** | `07-order-app-logs.txt`: order kept logging `health endpoint queried … outcome: ok` throughout — the app was **alive and serving**, disproving the crash theory. `05` reason was `Target.Timeout` (packets silently dropped) not `Connection refused` (which app-down would give). `06-fault-rule-absent.json`: order-sg:3001 ingress listed only payment-sg — the `alb-sg → order-sg:3001` rule was gone, vs baseline `00-baseline-rule.json` which had both alb-sg and payment-sg. |
| **Actual cause** | The `alb-sg → order-sg:3001` ingress rule was removed, so ALB health checks and traffic could not reach the order tasks. The application never had a problem. |
| **Repair** | `authorize-security-group-ingress --port 3001 --source-group $ALB_SG` restored the rule (`09-restore-result.json`). Targets returned to healthy (`12-settled-health.txt`: 2 healthy) and live traffic returned `status=200` (`13-final-curl.txt`). |
| **Prevention** | Codify SG rules as IaC (Terraform) so drift is detected and reverted; add a CloudWatch alarm on ALB `UnHealthyHostCount > 0`; record the heuristic "`Target.Timeout` = network/SG, `Connection refused` = app" in the runbook. |

### Notes for Demo 8
- **Diagnostic fingerprint:** `Target.Timeout` (dropped packets) distinguishes a
  firewall/SG block from an app that is down (`Connection refused`). This single
  reason string redirected the investigation from the app to the network layer.
- **Callback survived:** the revoke removed only the alb-sg source; the separate
  `payment-sg → order-sg:3001` rule remained (`06` still lists payment-sg), so the
  internal payment→order `/confirm` callback kept working while the public ALB
  path was down.
- **Cascade:** because ECS ties task health to the ALB health check, the sustained
  unhealthy state made ECS begin **replacing** the "unhealthy" order tasks — the
  churn visible in `10-recovery-health.txt` (old tasks draining, new ones starting).
  A pure network fault cascaded into task cycling.

**Done:** fault diagnosed from evidence with no reveal and no repair before
capture; written up as a scar entry.

---

## 4.3 Kill a task (Demo 5, availability)

Order runs **desired count 2**. Continuous traffic ran while one order task was
stopped; recovery was recorded. Raw output in `phase4-evidence/4.3-*`.

**Kill event: 19:43:04** (victim task on `172.31.4.149`).

| Time | Event (`4.3-service-events.txt`) |
|---|---|
| 19:43:04.035 | deregistered victim target `172.31.4.149` |
| 19:43:04.040 | began draining connections |
| 19:43:04.706 | replacement task `17cce1c0…` started |
| 19:43:43.476 | new target `172.31.12.194` registered healthy |

### Signals recorded

| Signal | Observation |
|---|---|
| Failed requests | **0** — every line in `4.3-traffic-loop.txt` is `status=200` |
| Non-200 responses | **0** |
| Slow requests | **0 attributable to the kill** (only pre-kill blips 0.687s @19:42:17, 0.917s @19:42:28; at kill time ~0.53s) |
| Replacement task start | 19:43:04.706 (task `17cce1c0825144d88e6e4ad59bebce6b`) |
| New target registration | 19:43:43.476 (`172.31.12.194`) |
| Target health transition | victim `172.31.4.149`: healthy→draining; new `172.31.12.194`: →healthy; survivor `172.31.17.136`: healthy throughout (`4.3-target-health-watch.txt`) |
| Total recovery time | **~39.4 s infrastructure** (deregister → new target healthy); **user-facing downtime = 0** |

### Availability questions (Demo 5)

1. **Why did ECS replace the task?** The service scheduler enforces desired
   count = 2. Running (1) < desired (2) triggered an immediate replacement —
   `started 1 tasks 17cce1c0…` at 19:43:04.706, ~0.7 s after the stop.
2. **How did the ALB avoid an unhealthy target?** The stopped task was
   deregistered and drained before it could serve errors. The ALB kept routing
   only to the survivor `172.31.17.136` (healthy throughout); the replacement
   received traffic only after passing health checks at 19:43:43. Zero non-200s.
3. **Did Service Connect require reconfiguration?** No. SC/Cloud Map resolves by
   name; the replacement task registered automatically. No manual change.
4. **What changes if desired count were 1?** No warm standby — a real outage
   (5xx/timeouts) for the full ~39 s until the replacement passed health checks.
   The evidence (0 failed requests at desired=2) is the concrete justification
   for running order at 2.

**Done:** signals table filled from real output; four questions answered from
observation.

---

## Definition of done — Phase 4 (order)

- [x] Trace table complete with per-hop evidence; one request ID across all three services
- [x] Phase 1 predictions revisited
- [x] One sabotage/diagnosis cycle captured as a scar entry (no reveal, no early repair)
- [x] Kill exercise signals recorded and the four availability questions answered
- [ ] Investigate a teammate's injected fault (pending their round)

**Most instructive scar for Demo 8:** the blocking SG rule — the app was 100%
healthy yet the ALB reported it down, and the `Target.Timeout` reason (not
`Connection refused`) was the single clue that redirected the whole investigation
from the application to the network layer.
