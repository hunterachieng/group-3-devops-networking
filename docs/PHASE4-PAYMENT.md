# Phase 4 — Payment Service Evidence Log
**Owner:** Wairimu | **Service:** payment (hop C) | **Cluster:** `devops-g3-cluster`
**Region:** `us-west-1` | **Account:** `827478161993`

**Status:** 4.1 ✅ complete · 4.2a ✅ complete · 4.2b ✅ complete · 4.3 ✅ complete
— all four exercises done with real, verified evidence.

Two things specific to payment, not order:
- **No ALB** — payment is only reachable inside the cluster via Service
  Connect DNS (`http://payment:3003`), so traffic in 4.3 is generated from
  inside an Inventory task, not from a laptop.
- **Desired count 1** — killing payment's only task is a real outage
  window, not a zero-impact failover test like order's desired-count-2 setup.

---

## 4.1 — Confirm payment's log shows the B→C hop + the callback to Order

### Step 4.1.1 — Fire one checkout with a correlation ID we control

**Command:**
```bash
export RID="phase4-payment-$(date +%s)"
curl -sS -X POST "http://$ALB_DNS/checkout" \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: $RID" \
  -d '{"items":["SKU-1"],"amount":4200}' \
  | tee phase4-evidence/4.1-checkout-response.txt
```

**Output:**
```
{"order_id":"ORD-CB5EA356","outcome":"success","pipeline":{"downstream":{"amount":4200,"confirm":"sent","order_id":"ORD-CB5EA356","outcome":"success","request_id":"phase4-payment-1784750363","service":"payment-service"},"order_id":"ORD-CB5EA356","outcome":"success","request_id":"phase4-payment-1784750363","service":"inventory-service"},"request_id":"phase4-payment-1784750363","service":"order-service"}
```

**Explanation:** We mint `$RID` ourselves instead of letting order generate
one, so we know exactly which string to grep for in every downstream log.
This single request is expected to travel `order → inventory → payment`,
then `payment → order` (the confirm callback).

### Step 4.1.2 — Pull payment's own log for the B→C hop

**Command:**
```bash
aws logs tail /ecs/devops-g3/payment --since 5m --region $AWS_REGION \
  | grep "$RID" | tee phase4-evidence/4.1-payment-log.txt
```

**Output:**
```
2026-07-22T19:59:24.530000+00:00 ecs/payment/65f8be3e9e2344fb99b4a995ab2d9f97 {"timestamp": "2026-07-22T19:59:24.530546+00:00", "level": "INFO", "service": "payment-service", "message": "charge request received from Inventory", "request_id": "phase4-payment-1784750363", "trace_id": "8152ab7f0dceb80c2cd8767a15f8f56c", "span_id": "8e73bc2042f242d4", "event": "charge_received", "order_id": "ORD-CB5EA356", "method": "POST", "path": "/charge", "amount": 4200}
2026-07-22T19:59:24.531000+00:00 ecs/payment/65f8be3e9e2344fb99b4a995ab2d9f97 {"timestamp": "2026-07-22T19:59:24.530920+00:00", "level": "INFO", "service": "payment-service", "message": "payment captured", "request_id": "phase4-payment-1784750363", "trace_id": "8152ab7f0dceb80c2cd8767a15f8f56c", "span_id": "8e73bc2042f242d4", "event": "payment_captured", "order_id": "ORD-CB5EA356", "amount": 4200, "outcome": "ok"}
2026-07-22T19:59:24.581000+00:00 ecs/payment/65f8be3e9e2344fb99b4a995ab2d9f97 {"timestamp": "2026-07-22T19:59:24.581331+00:00", "level": "INFO", "service": "payment-service", "message": "notifying Order that payment confirmed", "request_id": "phase4-payment-1784750363", "trace_id": "8152ab7f0dceb80c2cd8767a15f8f56c", "span_id": "8e73bc2042f242d4", "event": "confirming_order", "order_id": "ORD-CB5EA356", "target": "http://order:3001"}
2026-07-22T19:59:24.592000+00:00 ecs/payment/65f8be3e9e2344fb99b4a995ab2d9f97 {"timestamp": "2026-07-22T19:59:24.592678+00:00", "level": "INFO", "service": "payment-service", "message": "charge complete", "request_id": "phase4-payment-1784750363", "trace_id": "8152ab7f0dceb80c2cd8767a15f8f56c", "span_id": "8e73bc2042f242d4", "event": "charge_completed", "order_id": "ORD-CB5EA356", "status": 200, "outcome": "success", "confirm": "sent", "duration_ms": 62.3}
```

**Explanation:** Expected lines, in order, all carrying the same
`request_id`: `charge_received` → `payment_captured` → `confirming_order` →
`charge_completed` with `"confirm":"sent"`. This proves Inventory's call
into payment actually happened and was processed — not just that the
network path is open.

### Step 4.1.3 — Pull Order's log for the confirm callback

**Command:**
```bash
aws logs tail /ecs/devops-g3/order --since 5m --region $AWS_REGION \
  | grep "$RID" | tee phase4-evidence/4.1-order-confirm-log.txt
```

**Output:**
```
2026-07-22T19:59:24.102000+00:00 ecs/order/39d88d86598f49c9a2d1fc9703f54888 {"timestamp": "2026-07-22T19:59:24.102116+00:00", "level": "INFO", "service": "order-service", "message": "customer checkout received", "request_id": "phase4-payment-1784750363", "event": "checkout_received", "order_id": "ORD-CB5EA356", "method": "POST", "path": "/checkout", "amount": 4200}
2026-07-22T19:59:24.102000+00:00 ecs/order/39d88d86598f49c9a2d1fc9703f54888 {"timestamp": "2026-07-22T19:59:24.102238+00:00", "level": "INFO", "service": "order-service", "message": "asking Inventory to reserve stock", "request_id": "phase4-payment-1784750363", "event": "reserving_inventory", "order_id": "ORD-CB5EA356", "target": "http://inventory:3002"}
2026-07-22T19:59:24.588000+00:00 ecs/order/39d88d86598f49c9a2d1fc9703f54888 {"timestamp": "2026-07-22T19:59:24.588775+00:00", "level": "INFO", "service": "order-service", "message": "payment confirmed; order complete", "request_id": "phase4-payment-1784750363", "trace_id": "8152ab7f0dceb80c2cd8767a15f8f56c", "span_id": "8e73bc2042f242d4", "event": "order_confirmed", "order_id": "ORD-CB5EA356", "path": "/confirm", "source": "payment-service", "detail": {"order_id": "ORD-CB5EA356", "amount": 4200, "confirmed_by": "payment-service"}, "outcome": "ok"}
2026-07-22T19:59:24.625000+00:00 ecs/order/39d88d86598f49c9a2d1fc9703f54888 {"timestamp": "2026-07-22T19:59:24.625385+00:00", "level": "INFO", "service": "order-service", "message": "checkout pipeline finished", "request_id": "phase4-payment-1784750363", "event": "checkout_completed", "order_id": "ORD-CB5EA356", "status": 200, "outcome": "success", "duration_ms": 523.4}
```

**Explanation:** Expected: an `order_confirmed` event carrying the same
`request_id`. This is the proof the deliberate reverse edge
(`payment → order` on port 3001) actually closed the loop — the one edge
that's an intentional exception to the A→B→C-only rule from Gate 2.

**✅ Done — verified.** `phase4-payment-1784750363` (decodes to
`19:59:23 UTC`, matching the log timestamps) appears in both
`4.1-payment-log.txt` and `4.1-order-confirm-log.txt`, and the payment log
shows `"confirm":"sent"`. Trace ID `8152ab7f0dceb80c2cd8767a15f8f56c` ties
payment's `charge_received`→`charge_completed` to order's
`order_confirmed`, confirming the full A→B→C→A round trip on
`ORD-CB5EA356`.

---

## 4.2a — Privately picked fault injection on payment

**Fault chosen:** Insufficient memory — container-level hard memory limit
set to **32 MB** (task-level memory kept at 512 MB, the Fargate-required
floor at 256 CPU). This is a second attempt: an earlier run at 128 MB
survived cleanly under idle load, so this run deliberately went much
lower to actually trigger the fault.

Options considered:

| Fault | Inject | Expected symptom |
|---|---|---|
| Wrong health-check path | task-def `/healthz` instead of `/health`, redeploy | target unhealthy → 502/503 |
| Nonexistent image tag | deploy task-def with `:doesnotexist` | task never RUNNING, `CannotPullContainerError` |
| **Insufficient memory (chosen)** | container-level memory limit set low, redeploy | task stops or OOMs, or may not manifest under idle load |
| Blocking SG rule | revoke `payment-sg` inbound from `inventory-sg:3003` | timeouts from Inventory, no direct symptom on payment's own health check |

### Step 4.2a.1 — Record the moment of injection

**Command:**
```bash
date | tee phase4-evidence/4.2-fault-inject-time.txt
```

**Output:**
```
Wed Jul 22 23:05:06 EAT 2026
```

**Explanation:** The golden rule for this exercise is capturing evidence
*before* any repair — the exact injection time anchors everything that
follows on a timeline.

### Step 4.2a.2 — Inject the fault (container-level memory = 32 MB)

**Command:**
```bash
aws ecs describe-task-definition --task-definition devops-g3-payment \
  --region us-west-1 --query 'taskDefinition.containerDefinitions[0].image' --output text
```
**Output:**
```
827478161993.dkr.ecr.us-west-1.amazonaws.com/devops-g3-payment:46880cd
```

Broken task definition (`/tmp/task-def-broken.json`): identical to the
known-good `:1` revision except `containerDefinitions[0].memory` set to
`32` (task-level `memory` stays `512`, `cpu` stays `256`).

```bash
aws ecs register-task-definition --cli-input-json file:///tmp/task-def-broken.json \
  --region us-west-1 --query 'taskDefinition.taskDefinitionArn' --output text
```
**Output:**
```
arn:aws:ecs:us-west-1:827478161993:task-definition/devops-g3-payment:3
```

```bash
aws ecs update-service --cluster devops-g3-cluster --service devops-g3-payment \
  --task-definition devops-g3-payment --region us-west-1 \
  --query 'service.deployments[0].{taskDef:taskDefinition,rollout:rolloutState}'
```
**Output:**
```
{
    "taskDef": "arn:aws:ecs:us-west-1:827478161993:task-definition/devops-g3-payment:3",
    "rollout": "IN_PROGRESS"
}
```

**Explanation:** Registering a new revision and pointing the service at it
is how any task-def-level fault gets deployed — health-check path, image
tag, and memory faults all follow this same pattern; only the JSON edit
differs. Note this registered as revision `:3`, not `:2` — the earlier
128 MB attempt's revision is still on record, so revision numbers don't
reset between attempts.

### Step 4.2a.3 — Capture the broken state (before touching anything else)

**Command:**
```bash
sleep 20
aws ecs describe-services --cluster devops-g3-cluster --services devops-g3-payment \
  --region us-west-1 --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,taskDef:taskDefinition}'

aws ecs describe-services --cluster devops-g3-cluster --services devops-g3-payment \
  --region us-west-1 --query 'services[0].events[0:8].[createdAt,message]' \
  --output table | tee phase4-evidence/4.2-broken-service-events.txt
```

**Output:**
```
{
    "desired": 1,
    "running": 1,
    "pending": 1,
    "taskDef": "arn:aws:ecs:us-west-1:827478161993:task-definition/devops-g3-payment:3"
}
```
```
-------------------------------------------------------------------------------------------------------------------------------------------
|                                                            DescribeServices                                                             |
+-----------------------------------+-----------------------------------------------------------------------------------------------------+
|  2026-07-22T23:06:42.327000+03:00 |  (service devops-g3-payment) has started 1 tasks: (task 92752930650f4ee981f127d8cd6887e2).          |
|  2026-07-22T21:38:11.867000+03:00 |  (service devops-g3-payment) has reached a steady state.                                            |
|  2026-07-22T21:36:46.085000+03:00 |  (service devops-g3-payment) has started 1 tasks: (task 65f8be3e9e2344fb99b4a995ab2d9f97).          |
|  2026-07-22T21:16:18.325000+03:00 |  (service devops-g3-payment) has reached a steady state.                                            |
|  2026-07-22T21:16:18.324000+03:00 |  (service devops-g3-payment) (deployment ecs-svc/1245947851428932511) deployment completed.         |
|  2026-07-22T21:13:53.989000+03:00 |  (service devops-g3-payment) has stopped 1 running tasks: (task e514156d222348d0be2970a5d530453d).  |
|  2026-07-22T21:12:22.607000+03:00 |  (service devops-g3-payment) has started 1 tasks: (task 7453f1e1556f453faf18bcb148beb226).          |
|  2026-07-22T21:03:06.128000+03:00 |  (service devops-g3-payment) has reached a steady state.                                            |
+-----------------------------------+-----------------------------------------------------------------------------------------------------+
```

**Explanation:** Scheduler events narrate what ECS is doing in response to
the fault (repeated failed placements, health-check failures, etc.) —
this is the "what broken looked like" evidence the exercise requires.
`pending: 1` alongside `running: 1` shows ECS already mid-deployment,
about to discover the new task is unviable.

### Step 4.2a.4 — Inspect the failing task's detail

**Command:**
```bash
NEW_TASK=arn:aws:ecs:us-west-1:827478161993:task/devops-g3-cluster/92752930650f4ee981f127d8cd6887e2
aws ecs describe-tasks --cluster devops-g3-cluster --tasks $NEW_TASK --region us-west-1 \
  --query 'tasks[0].{lastStatus:lastStatus,stoppedReason:stoppedReason,health:containers[0].healthStatus,exitCode:containers[0].exitCode,reason:containers[0].reason}' \
  | tee phase4-evidence/4.2-broken-task-detail.txt
```

**Output (first check, task mid-shutdown):**
```
{
    "lastStatus": "DEPROVISIONING",
    "stoppedReason": "Essential container in task exited",
    "health": "UNKNOWN",
    "exitCode": 137,
    "reason": "OutOfMemoryError: container killed due to memory usage"
}
```
**Output (30s later, fully stopped):**
```
{
    "lastStatus": "STOPPED",
    "stoppedReason": "Essential container in task exited",
    "health": "UNKNOWN",
    "exitCode": 137,
    "reason": "OutOfMemoryError: container killed due to memory usage"
}
```

**Explanation:** `stoppedReason` is the single most diagnostic field —
`CannotPullContainerError` = bad image tag, mentions of `OutOfMemoryError`
= memory fault, `UNHEALTHY` with no stop = health-check-path or SG fault.
**This is a clean, unambiguous positive result:** `exitCode: 137` is the
standard SIGKILL signature for an OOM kill, and the `reason` field states
it explicitly. Confirms the fault genuinely manifested this time, unlike
the 128 MB attempt.

### Step 4.2a.5 — Repair, then capture recovery

**Command:**
```bash
aws ecs update-service --cluster devops-g3-cluster --service devops-g3-payment \
  --task-definition arn:aws:ecs:us-west-1:827478161993:task-definition/devops-g3-payment:1 \
  --region us-west-1 \
  --query 'service.deployments[0].{taskDef:taskDefinition,rollout:rolloutState}'

aws ecs wait services-stable --cluster devops-g3-cluster --services devops-g3-payment --region us-west-1

aws ecs describe-services --cluster devops-g3-cluster --services devops-g3-payment \
  --region us-west-1 --query 'services[0].{taskDef:taskDefinition,running:runningCount,desired:desiredCount}' \
  | tee phase4-evidence/4.2-recovered.txt
```

**Output:**
```
{
    "taskDef": "arn:aws:ecs:us-west-1:827478161993:task-definition/devops-g3-payment:1",
    "running": 1,
    "desired": 1
}
```

**Explanation:** Confirms the fix actually restored the service to its
target steady state, not just that a command ran without error — back on
revision `:1` (512 MB task memory, no container-level override), 1/1
running.

### Step 4.2a.6 — Scar log entry

```
Fault:            container-level hard memory limit set to 32 MB
                  (task-level memory kept at 512 MB, the Fargate-required
                  floor at 256 CPU). Second attempt — 128 MB (tried
                  previously) survived cleanly under idle load; 32 MB was
                  chosen specifically to force a real signal.
Symptom:          new task placed, then died within roughly 30-50 seconds
                  of starting; service showed running:1/pending:1 mid-
                  transition, then the task moved DEPROVISIONING -> STOPPED.
First hypothesis: gunicorn (2 workers) + Flask + the OTEL/Prometheus SDKs
                  would exceed 32 MB and get OOM-killed. (Correct, this
                  time.)
Evidence:         describe-tasks on the new task showed exitCode: 137
                  (SIGKILL) and reason: "OutOfMemoryError: container
                  killed due to memory usage" — an unambiguous, textbook
                  OOM signature.
Diagnosis:        Confirmed positive result. 32 MB is genuinely below what
                  the payment container needs even at idle; 128 MB is not.
                  The real ceiling for this container sits somewhere
                  between 32 MB and 128 MB under idle/health-check-only
                  load — narrower load testing could pin that down further
                  if needed, but wasn't required for this exercise.
Actual cause:     container-level memory limit (32 MB) — real OOM,
                  confirmed via exit code and stated reason.
Repair:           update-service back to task-definition revision :1
                  (512 MB task memory, no container-level override);
                  confirmed running:1, desired:1 on the known-good
                  revision after ecs wait services-stable returned.
Prevention:       this two-attempt sequence (128 MB survives, 32 MB OOMs)
                  is itself a useful data point for right-sizing: don't
                  pick a memory-fault ceiling by guessing — bisect between
                  a known-safe and a known-broken value if a genuine
                  positive result is required for a demo or test. Also:
                  ECS's own retry loop will keep re-attempting the same
                  broken definition (seen here as running:1/pending:1
                  immediately after the first OOM) — don't mistake that
                  ongoing retry for a stable, recovered state.
```

---

## 4.2b — Investigating a teammate's fault (symptom-first, service unknown)

**Result up front:** a real, transient fault was found — but not where the
first three steps looked. Order itself is healthy right now; the evidence
of an actual problem is buried in the log tail (step 4.2b.4), pointing at
**Inventory**, not Order.

### Step 4.2b.1 — Is the service even trying to run tasks?

**Command:**
```bash
export SERVICE=order
aws ecs describe-services --cluster $CLUSTER --services devops-g3-$SERVICE \
  --region $AWS_REGION --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}'
```

**Output:**
```
{
    "desired": 2,
    "running": 2,
    "pending": 0
}
```

**Explanation:** `running < desired` with `pending` stuck at 0 or cycling
tells you tasks are failing to start or stay up — narrows straight to a
task-def or image problem rather than a networking one. **Here, 2/2,
nothing pending** — no capacity problem right now.

### Step 4.2b.2 — What do the scheduler events say happened?

**Command:**
```bash
aws ecs describe-services --cluster $CLUSTER --services devops-g3-$SERVICE \
  --region $AWS_REGION --query 'services[0].events[0:8].[createdAt,message]' --output table
```

**Output:**
```
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
|                                                                                               DescribeServices                                                                                               |
+----------------------------------+---------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
|  2026-07-22T22:43:54.886000+03:00|  (service devops-g3-order) has reached a steady state.                                                                                                                    |
|  2026-07-22T22:43:54.885000+03:00|  (service devops-g3-order) (deployment ecs-svc/5900895824507767624) deployment completed.                                                                                 |
|  2026-07-22T22:37:04.224000+03:00|  (service devops-g3-order, taskSet ecs-svc/1214983551022201730) has begun draining connections on 2 tasks.                                                                |
|  2026-07-22T22:37:04.218000+03:00|  (service devops-g3-order) deregistered 2 targets in target-group devops-g3-order-tg                                                                                       |
|  2026-07-22T22:36:54.172000+03:00|  (service devops-g3-order) has stopped 2 running tasks: (task 70cf193c37234cb38e07f5c864467653) (task 2cd7d1d3d81747afbd77dc5073a72481).                                  |
|  2026-07-22T22:35:42.485000+03:00|  (service devops-g3-order) registered 1 targets in target-group devops-g3-order-tg                                                                                         |
|  2026-07-22T22:35:23.001000+03:00|  (service devops-g3-order) has started 1 tasks: (task 39d88d86598f49c9a2d1fc9703f54888).                                                                                  |
|  2026-07-22T22:34:51.674000+03:00|  (service devops-g3-order) has started 1 tasks: (task c82d62c69f964f52811512ea1de43583).                                                                                  |
+----------------------------------+---------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
```

**Explanation:** ECS narrates its own troubleshooting in plain English
here — failed placements, health-check failures, and deployment
rollbacks all show up as readable event messages. **This is a clean
rolling deploy** (two new tasks up, two old ones drained, steady state by
`22:43:54`) — no failures. Crucially, this deployment finished over **35
minutes before** the actual symptom shows up in step 4.2b.4, so the fault
is unrelated to this redeploy.

### Step 4.2b.3 — Why did the task stop, or why is it unhealthy?

**Command:**
```bash
TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-$SERVICE \
  --region $AWS_REGION --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --region $AWS_REGION \
  --query 'tasks[0].{lastStatus:lastStatus,stoppedReason:stoppedReason,health:containers[0].healthStatus,image:containers[0].image}'
```

**Output:**
```
{
    "lastStatus": "RUNNING",
    "stoppedReason": null,
    "health": "HEALTHY",
    "image": "827478161993.dkr.ecr.us-west-1.amazonaws.com/devops-g3-order:ff0c762"
}
```

**Explanation:** The `image` field alone catches a bad-tag fault instantly
(compare against the known-good SHA); `stoppedReason` catches memory and
pull errors; `health` with no `stoppedReason` at all usually means a
health-check-path or SG-level fault, since the task is technically running
but never reports healthy. **Here everything is clean** — `RUNNING`,
`HEALTHY`, no stop, correct image tag. Nothing wrong with order's own task
right now. On its own this step would say "no fault found" — the real
finding was still one step away.

### Step 4.2b.4 — Are logs reaching CloudWatch at all?

**Command:**
```bash
aws logs tail /ecs/devops-g3/$SERVICE --since 10m --region $AWS_REGION
```

**Output — the real finding, a burst of downstream failures (representative excerpt):**
```
2026-07-22T20:19:15.157000+00:00 ecs/order/c82d62c69f964f52811512ea1de43583 {"event": "checkout_received", "order_id": "ORD-30045C95", ...}
2026-07-22T20:19:15.157000+00:00 ecs/order/c82d62c69f964f52811512ea1de43583 {"event": "reserving_inventory", "order_id": "ORD-30045C95", "target": "http://inventory:3002"}
2026-07-22T20:19:15.160000+00:00 ecs/order/c82d62c69f964f52811512ea1de43583 {"level": "ERROR", "message": "inventory unreachable: 503 Server Error: Service Unavailable for url: http://inventory:3002/reserve", "event": "downstream_error", "order_id": "ORD-30045C95", "target": "http://inventory:3002", "outcome": "failure", "status": 502, "duration_ms": 3.3}
<pattern repeats every 1.5-3 seconds across both order tasks
(c82d62c6... and 39d88d86...), all failing the same way, from
20:19:15 through 20:19:58 UTC>
...
2026-07-22T20:20:00.047000+00:00 ecs/order/c82d62c69f964f52811512ea1de43583 {"event": "checkout_received", "order_id": "ORD-EECC31EA", ...}
2026-07-22T20:20:00.400000+00:00 ecs/order/c82d62c69f964f52811512ea1de43583 {"message": "payment confirmed; order complete", "event": "order_confirmed", "order_id": "ORD-EECC31EA", "source": "payment-service", "outcome": "ok"}
2026-07-22T20:20:00.420000+00:00 ecs/order/c82d62c69f964f52811512ea1de43583 {"event": "checkout_completed", "order_id": "ORD-EECC31EA", "status": 200, "outcome": "success", "duration_ms": 373.5}
<from this point on (20:20:00 through the end of the 10-minute tail,
~20:23:22 UTC), every checkout succeeds cleanly and health checks all
show "outcome": "ok" — no further downstream_error lines>
```

**Explanation:** An empty log group despite a RUNNING task usually points
at an execution-role or logging-config problem rather than the app itself;
log lines present but no successful requests points at the app logic or a
downstream dependency instead. **Here, a real transient failure window is
visible:** for about 45 seconds (`20:19:15`–`20:20:00` UTC, i.e.
`23:19:15`–`23:20:00` EAT), every single checkout on both order tasks
failed identically — `inventory unreachable: 503 Server Error` on
`http://inventory:3002/reserve`, surfaced to the customer as a `502`. Then,
just as abruptly, it stopped: the very next checkout attempt
(`ORD-EECC31EA`) succeeded end to end, and every request afterward stayed
clean for the rest of the log window.

**Follow-up run — Inventory's own logs for the same period:**
```bash
aws logs tail /ecs/devops-g3/inventory --since 15m --region $AWS_REGION
```

**Output (representative excerpt, task `953b048f762e444fbf8f16aacf4d1348`):**
```
2026-07-22T20:20:03.629815+00:00 {"message": "stock reserved for order", "event": "stock_reserved", "order_id": "ORD-0CAA4DAE", "outcome": "ok"}
2026-07-22T20:20:03.629912+00:00 {"message": "handing off to Payment to charge", "event": "charging_payment", "order_id": "ORD-0CAA4DAE", "target": "http://payment:3003"}
2026-07-22T20:20:03.694790+00:00 {"message": "reserved and payment handed off", "event": "reserve_completed", "order_id": "ORD-0CAA4DAE", "status": 200, "outcome": "success", "duration_ms": 65.2}
<every reserve_received -> stock_reserved -> charging_payment ->
reserve_completed cycle from here through the end of the tail
(~20:35:18 UTC — over 15 minutes) succeeds cleanly with status 200, all
on the same task ID — no restarts, no errors, no health-check failures>
2026-07-22T20:20:03.974000+00:00 Transient error HTTPConnectionPool(host='jaeger', port=4318): Max retries exceeded... (Failed to resolve 'jaeger')
<this Jaeger OTLP export noise recurs roughly every 30s for the entire
tail — same root cause already diagnosed and fixed on payment:
OTEL_SDK_DISABLED has not been applied to Inventory's task definition>
```

**Follow-up run — Inventory's own service events (the piece that closes this out):**
```bash
aws ecs describe-services --cluster $CLUSTER --services devops-g3-inventory \
  --region $AWS_REGION --query 'services[0].events[0:15].[createdAt,message]' --output table
```

**Output (converted to UTC for direct comparison with Order's log
timestamps; original events are in EAT, +03:00):**
```
20:19:58.972 UTC  (service devops-g3-inventory) has reached a steady state.
20:18:41.569 UTC  (service devops-g3-inventory) has started 1 tasks: (task 953b048f762e444fbf8f16aacf4d1348).
20:10:00.989 UTC  (service devops-g3-inventory) has reached a steady state.
20:08:23.242 UTC  (service devops-g3-inventory) has started 1 tasks: (task aea3606728048b1a652c3612aff9244).
19:49:03.060 UTC  (service devops-g3-inventory) has reached a steady state.
19:49:03.059 UTC  (service devops-g3-inventory) (deployment ecs-svc/1675294001379389663) deployment completed.
19:47:30.309 UTC  (service devops-g3-inventory) has stopped 1 running tasks: (task 0668979337dc48ebb791640cd1162053).
19:47:30.299 UTC  (service devops-g3-inventory) (task 0668979337dc48ebb791640cd1162053) failed container health checks.
19:46:10.266 UTC  (service devops-g3-inventory) has started 1 tasks: (task 22450d8cbf7b4648ac0837b9a710e807).
19:45:52.149 UTC  (service devops-g3-inventory) rolling back to deployment ecs-svc/1675294001379389663.
19:45:52.148 UTC  (service devops-g3-inventory) (deployment ecs-svc/1571272475813219068) deployment failed: tasks failed to start.
19:44:48.096 UTC  (service devops-g3-inventory) has stopped 1 running tasks: (task 60a736a708f44dfcb1191e0771825ad5).
19:44:48.095 UTC  (service devops-g3-inventory) (task 60a736a708f44dfcb1191e0771825ad5) failed container health checks.
19:44:48.057 UTC  (service devops-g3-inventory) has started 1 tasks: (task 0668979337dc48ebb791640cd1162053). Amazon ECS replaced 1 tasks due to an unhealthy status.
19:42:25.306 UTC  (service devops-g3-inventory) has started 1 tasks: (task 60a736a708f44dfcb1191e0771825ad5).
```

**Diagnosis: confirmed, not just hypothesized.** Line up the timestamps
directly against Order's log window:

| Time (UTC) | Event |
|---|---|
| `20:18:41.569` | Inventory starts a new task: `953b048f...` |
| `20:19:15` | Order's **first** `503` against Inventory |
| *(45s of continuous 503s)* | new task still booting / clearing its health check |
| `20:19:58.972` | Inventory service reaches **steady state** on the new task |
| `20:20:00` | Order's **first** successful checkout (`ORD-EECC31EA`) |

The gap between task start and first failure (34s) matches a normal
gunicorn/Flask boot plus `startPeriod`; steady state landed **1 second
before** Order's first success. This is a confirmed task-replacement gap,
not circumstantial — during the ~77 seconds Inventory had no task both
registered *and* passing its health check, every Order request failed
with `503`, and recovery was instant once the new task went healthy.

**A separate, earlier incident is also visible in these events** (not the
cause of the 503 window investigated here, but worth noting): between
`19:42:25` and `19:49:03` UTC, Inventory went through a rocky deployment —
two tasks (`60a736a7...`, `0668979337...`) each failed their container
health checks and were replaced, and one deployment attempt
(`ecs-svc/1571272475813219068`) failed outright and rolled back. That
settled into steady state over 30 minutes before the incident investigated
here, so it's unrelated — but it strongly suggests Inventory was already
going through its own fault-injection exercise (Joynce's 4.2a, most
likely) earlier in this same session, and the `953b048f...` replacement at
`20:18:41` was a later, separate routine deployment that happened to
create a normal but real availability gap.

**Action items to hand back to Joynce:**
1. Confirm what triggered the `953b048f...` deployment at `20:18:41` UTC —
   if it was a manual redeploy, this ~77s gap is worth documenting as
   Inventory's own 4.3-equivalent evidence (a real, measured outage
   window from a task replacement, same class of finding as payment's).
2. Same `OTEL_SDK_DISABLED=true` fix needed on Inventory's task definition
   — third service now confirmed with this gap (payment, order, inventory).

---

## 4.3 — Non-200 / slow request counts during the kill (payment)

**Two-terminal pattern** — Terminal A ran a continuous traffic loop from
inside Inventory (payment's real caller, since payment has no ALB),
Terminal B killed the task and watched recovery. Both ran in the same
sitting, so the loop genuinely spans the full outage.

### Terminal A — traffic loop (ran from inside Inventory, single-line form)

**Command actually used** (single-line, to avoid the ECS Exec session
echoing its continuation prompt mid-paste and corrupting a multi-line
version):
```bash
while true; do date +%H:%M:%S; curl -s -o /dev/null -w 'status=%{http_code} time=%{time_total}\n' --max-time 3 http://payment:3003/health; sleep 1; done
```

**Output (baseline, before the kill):**
```
21:04:19 status=200 time=0.041054
21:04:20 status=200 time=0.007567
21:04:21 status=200 time=0.004848
... (steady status=200, ~4-5ms, for the full baseline period) ...
21:04:55 status=200 time=0.004726
```

**Explanation:** Run from inside Inventory rather than a laptop, since
payment isn't internet-reachable. Running the loop as one line (using `;`
instead of `\` line-continuations) sidestepped a paste-corruption issue
that broke earlier attempts — SSM sessions echo their own prompt back
mid-paste on multi-line input, garbling the command.

### Terminal B — capture "before", then kill payment's only task

**Command:**
```bash
export AWS_PAGER=""
export AWS_REGION=us-west-1
export CLUSTER=devops-g3-cluster

PAY_TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-payment \
  --region $AWS_REGION --query 'taskArns[0]' --output text)
echo "VICTIM=$PAY_TASK"
date
aws ecs stop-task --cluster $CLUSTER --task "$PAY_TASK" \
  --reason "phase4 availability test" --region $AWS_REGION \
  --query 'task.{arn:taskArn,stopping:lastStatus}' --output table
```

**Output:**
```
VICTIM=arn:aws:ecs:us-west-1:827478161993:task/devops-g3-cluster/1461c062da1644de870024a559c359fa
Thu Jul 23 00:04:40 EAT 2026
------------------------------------------------------------------------------------------------------------
|                                                 StopTask                                                 |
+----------+-----------------------------------------------------------------------------------------------+
|  arn     |  arn:aws:ecs:us-west-1:827478161993:task/devops-g3-cluster/1461c062da1644de870024a559c359fa   |
|  stopping|  DEACTIVATING                                                                                 |
+----------+-----------------------------------------------------------------------------------------------+
```
Kill issued at `00:04:40 EAT` = `21:04:40 UTC` (loop timestamps are UTC,
matching the container's clock).

**Explanation:** Recording the victim task ARN and exact wall-clock kill
time is what lets the traffic loop's timestamps be lined up against the
moment of failure.

### Terminal B — watch recovery

**Command:**
```bash
aws ecs describe-tasks --cluster $CLUSTER \
  --tasks $(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-payment --region $AWS_REGION --query 'taskArns[0]' --output text) \
  --region $AWS_REGION --query 'tasks[0].{status:lastStatus,health:containers[0].healthStatus}'

aws ecs describe-services --cluster $CLUSTER --services devops-g3-payment \
  --region $AWS_REGION --query 'services[0].events[0:8].[createdAt,message]' --output table
```

**Output:**
```
{
    "status": "RUNNING",
    "health": "HEALTHY"
}
```
```
-------------------------------------------------------------------------------------------------------------------------------------------
|                                                            DescribeServices                                                             |
+-----------------------------------+-----------------------------------------------------------------------------------------------------+
|  2026-07-23T00:06:36.004000+03:00 |  (service devops-g3-payment) has reached a steady state.                                            |
|  2026-07-23T00:04:58.862000+03:00 |  (service devops-g3-payment) has started 1 tasks: (task e33d0934038c4a4e925fcbb9ae7a61c2).          |
|  2026-07-22T23:46:02.667000+03:00 |  (service devops-g3-payment) has reached a steady state.                                            |
|  2026-07-22T23:44:24.950000+03:00 |  (service devops-g3-payment) has started 1 tasks: (task 1461c062da1644de870024a559c359fa).          |
+-----------------------------------+-----------------------------------------------------------------------------------------------------+
```

**Explanation:** Because payment has no second task to fail over to, this
sequence — task stops, scheduler notices, a replacement is placed, the
replacement passes its health check — *is* the entire outage window, not
just a formality. Replacement task `e33d0934...` started at
`00:04:58.862 EAT` (`21:04:58.862` UTC), and the service reached steady
state at `00:06:36.004 EAT` (`21:06:36.004` UTC).

### Terminal A — stop the loop, save it, compute the impact

Full loop output copied and saved to `phase4-evidence/4.3-payment-traffic-loop.txt`.

**Command — total requests:**
```bash
wc -l < phase4-evidence/4.3-payment-traffic-loop.txt
```
**Output:**
```
356
```

**Command — non-200 requests:**
```bash
grep -c "status=503" phase4-evidence/4.3-payment-traffic-loop.txt
```
**Output:**
```
111
```

**Command — first and last failed request timestamps:**
```bash
grep "status=503" phase4-evidence/4.3-payment-traffic-loop.txt | head -1
grep "status=503" phase4-evidence/4.3-payment-traffic-loop.txt | tail -1
```
**Output:**
```
21:04:56 status=503 time=0.477409
21:06:49 status=503 time=0.001132
```

**Command — last good request before, first good request after:**
```bash
grep -B1 "status=503" phase4-evidence/4.3-payment-traffic-loop.txt | head -1
grep -A1 "status=503" phase4-evidence/4.3-payment-traffic-loop.txt | tail -1
```
**Output:**
```
21:04:55 status=200 time=0.004726
21:06:50 status=200 time=0.035698
```

**Summary table:**
```
Total requests during test:        356
Non-200 (503) requests:            111
First failed request timestamp:    21:04:56 UTC
Last failed request timestamp:     21:06:49 UTC
Total outage window (HTTP-level):  115 seconds (21:04:55 last good ->
                                    21:06:50 first good after)
Failure streak duration:           114 seconds (21:04:56 -> 21:06:49,
                                    111 consecutive failed requests)
```

**Cross-check against the ECS-level timeline (both measurements agree):**
```
21:04:40   stop-task issued
21:04:56   first HTTP failure (16s after kill — matches old task
           draining + Service Connect losing the route)
21:04:58.862  replacement task started (ECS event)
21:06:36.004  service reaches steady state (ECS event)
21:06:49   last HTTP failure
21:06:50   first HTTP success
```
The ECS "steady state" timestamp (`21:06:36`) lands about 13 seconds
*before* the HTTP loop's first recorded success (`21:06:50`) — consistent
with Service Connect's own DNS/routing propagation taking a few extra
seconds after the task itself reports healthy, on top of the container
health check's own `interval`/`retries` timing.

**Explanation:** This is the concrete "how bad was it" answer. A **115
second continuous outage**, with **111 failed requests** at one per
second, is a real and measurable cost of running payment at desired count
1 — unlike order's desired-count-2 setup, there was no second task to
absorb traffic during the replacement. Every single request in that
window failed with `503`; there was no partial degradation, no slow
responses that still succeeded — it was a hard, binary outage for the
full duration. This is the single strongest piece of evidence in this
whole exercise for why desired count 1 is a real production risk for a
service other components depend on synchronously.

---

## Summary — all four Phase 4 exercises, payment service

| Exercise | Result |
|---|---|
| **4.1 Trace** | Confirmed A→B→C→A round trip on `ORD-CB5EA356`; payment's B→C hop and the deliberate payment→order confirm callback both proven with matching `request_id`/`trace_id` |
| **4.2a Sabotage (own fault)** | Container memory limit of 32 MB produces a real, confirmed OOM (`exitCode 137`); 128 MB (tried first) survives — genuine dose-response finding |
| **4.2b Investigate (teammate's fault)** | Order was healthy throughout; root cause of a real 45s customer-facing incident traced to a confirmed 77s Inventory task-replacement gap, timestamps matching to the second |
| **4.3 Kill-a-task** | 115-second real outage, 111/356 requests failed (all `503`, no partial degradation), HTTP-level and ECS-level measurements cross-checked and consistent |

**Cross-cutting finding:** all three services (payment, order, inventory)
are missing `OTEL_SDK_DISABLED=true` in their task definitions except
payment, which was fixed during 4.2a. Worth raising as a group action item
independent of the four exercises above.
