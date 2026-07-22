# Payment Service — Phase 2 Execution Runbook
**Owner:** Wairimu | **Service:** payment | **Port:** 3003 | **Desired count:** 1
**Cluster:** `devops-g3-cluster` | **Account:** `827478161993` | **Region:** `us-west-1`
**Status as of this write-up:** deployed and live — task `RUNNING`, container
`HEALTHY`, CloudWatch logs flowing. Checks 4-5 (SHA via ECS Exec, shell
access) pending the Session Manager plugin install on the operator's
machine — see §11.

This document explains every command run to get the payment service live
on ECS Fargate, why each decision was made, and how to prove the Phase 2
checkpoint. All commands are plain `aws` / `docker` CLI — no shell scripts
involved. `task-definition-payment.json` is the one supporting file, used
directly as input to `register-task-definition`.

**Repo layout note:** the group standardized on an `infra/<service>/`
convention for deployment tooling — Hunter's order files live in
`infra/order/`, and `task-definition-payment.json` lives in `infra/payment/`,
two directories below the repo root (`../..` from there).

---

## 0. What I found already in the repo (don't redo this)

Before running anything, I unzipped the repo and checked `payment/` against
the Track 2 checklist. Good news — the shared repo track is already done for
payment:

| Requirement | Status |
|---|---|
| Self-contained `payment/` build context | Done — has its own Dockerfile, `app.py`, `common/`, `requirements.txt` |
| Non-root user | Done — `useradd appuser` / `USER appuser` |
| Binds `0.0.0.0` | Done — `BIND_HOST=0.0.0.0` |
| curl present | Done — installed in the base layer |
| gunicorn as PID 1 (exec-form CMD) | Done |
| `GIT_SHA` baked in via `ARG`/`ENV` | Done |
| `/version` endpoint | Done — returns `{"service":"payment","version":"<sha>","status":"ok"}` |
| `/health` endpoint (200 when up) | Done |
| JSON logs on stdout | Done — shared `common/logging_setup.py` used by all three services |
| `.dockerignore` | Done |
| `buildspecs/payment.yml` | Done (Phase 5 stub, correct shape) |

So this runbook only covers what's genuinely **Wairimu's remaining work**:
engineer machine setup, ECR, build/tag/push, the dedicated SG, task
definition registration, ECS service creation, and the live checkpoint.

---

## 1. A discrepancy I resolved (read this first)

Two source documents disagree on two values. I went with the **Track 1
handover** (`track1-platform-handover.md`) over the **working plan**
(`phase2-hosting-plan.md`) wherever they conflict, because the handover
describes what the platform team (Minage & Lwam) **actually created** in
AWS — it's the ground truth, not the plan.

| Item | Working plan says | Handover says (what actually exists) | Used |
|---|---|---|---|
| Log group name | `devops-g3-payment-logs` | `/ecs/devops-g3/payment` (already created, 14-day retention) | `/ecs/devops-g3/payment` |
| `Project` tag value | `devops-mentorship` | `devops-Ecommerce` | `devops-Ecommerce` |

**Action for the group:** flag this to Hunter and Joynce so their task
definitions/services use the same two values — otherwise your three
services will be tagged and logged inconsistently, and cross-service log
correlation in Phase 3 gets harder.

---

## 2. Engineer machine ready

```bash
aws --version
```
Expected: `aws-cli/2.x.x ...`. If not found, install:
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

Configure it for the shared account:
```bash
aws configure
# Region: us-west-1, output format: json
aws sts get-caller-identity --region us-west-1
```
Expected: `"Account": "827478161993"` in the output.

Install the Session Manager plugin (needed for `execute-command` later):
```bash
brew install --cask session-manager-plugin
session-manager-plugin
```
Expected: version info printed, not "command not found".

Confirm the platform cluster is ready before doing anything else:
```bash
aws ecs describe-clusters --clusters devops-g3-cluster --region us-west-1 \
  --query "clusters[0].status" --output text
```
Expected: `ACTIVE`.

---

## 3. Dockerfile — already correct, verified against every contract

`payment/Dockerfile` was checked line-by-line against the "before
registration" answers table in the working plan:

- Listens on `0.0.0.0:3003` ✔
- `gunicorn` is PID 1 via exec-form `CMD` ✔ — SIGTERM reaches gunicorn
  directly, which drains workers over `--graceful-timeout 30` before exit
- `curl` baked into the image ✔ — needed for both the container health
  check and ECS Exec debugging (you can't `apt-get install` inside a running
  Fargate task)
- Runs as `appuser`, not root ✔
- One extra good practice already present: `PROMETHEUS_MULTIPROC_DIR` is
  created and `chown`'d to `appuser` **before** the `USER appuser` switch —
  correct order, since doing it after would fail at startup with a
  permissions error.

No changes needed here.

---

## 4. Build, tag, push

Set the values used throughout the rest of this runbook:
```bash
REGION="us-west-1"
ACCOUNT="827478161993"
CLUSTER="devops-g3-cluster"
SHA=$(git rev-parse --short HEAD)
```

Authenticate Docker to ECR:
```bash
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
```
Expected: `Login Succeeded`.

Build for Fargate (linux/amd64 — mandatory even on Apple Silicon):
```bash
docker build --platform linux/amd64 --build-arg GIT_SHA=$SHA \
  -t devops-g3-payment:$SHA ./payment
```

Tag and push (never `latest` — the ECR repo is immutable-tagged, and a
mutable `latest` tag defeats the entire point of the `/version` checkpoint):
```bash
docker tag devops-g3-payment:$SHA $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/devops-g3-payment:$SHA
docker push $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/devops-g3-payment:$SHA
```

If the ECR repo doesn't exist yet, create it first (idempotency check, skip
if it already exists):
```bash
aws ecr describe-repositories --repository-names devops-g3-payment --region $REGION \
  || aws ecr create-repository --repository-name devops-g3-payment --region $REGION \
       --image-tag-mutability IMMUTABLE \
       --tags Key=Project,Value=devops-Ecommerce Key=Group,Value=group-3 \
              Key=Owner,Value=payment-owner Key=Environment,Value=lab
```

---

## 5. Dedicated security group

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --region $REGION --query "Vpcs[0].VpcId" --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name devops-g3-payment-sg \
  --description "Dedicated SG for devops-g3 payment service (Phase 2 - isolated, no cross-service rules yet)" \
  --vpc-id $VPC_ID \
  --region $REGION \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=devops-Ecommerce},{Key=Group,Value=group-3},{Key=Owner,Value=payment-owner},{Key=Environment,Value=lab}]" \
  --query "GroupId" --output text)
echo $SG_ID
```

Note the description uses a plain hyphen `-`, not an em dash — AWS resource
descriptions/tags are ASCII-only and will reject smart punctuation.

**Deliberately no inbound rules.** Reasoning:

- ECS container health checks run *inside* the task via the Docker/ECS
  agent (`CMD-SHELL curl ...`), not over the network from outside — no
  inbound rule needed.
- `aws ecs execute-command` tunnels through Systems Manager, not a direct
  network path into the SG — no inbound rule needed for ECS Exec either.
- There's no ALB and no cross-service traffic in Phase 2 (explicitly
  deferred to Phase 3: Service Connect namespace, the four cross-service SG
  rules, the ALB, and the target group).

Default AWS-managed egress (allow all outbound) is left in place so the
task can reach ECR (image pull) and CloudWatch Logs (log shipping).

---

## 6. Task definition (`task-definition-payment.json`)

| Setting | Value | Why |
|---|---|---|
| `family` | `devops-g3-payment` | matches ECR repo / service naming convention |
| `networkMode` | `awsvpc` | required for Fargate |
| `requiresCompatibilities` | `FARGATE` | no EC2 capacity to manage |
| `cpu` / `memory` | `256` / `512` | smallest Fargate combo that comfortably holds a 2-worker Flask/Gunicorn app + curl. Revisit only if a task gets OOM-killed |
| `executionRoleArn` | `devops-g3-execution-role` | ECS uses this to pull the image and write logs — **not** the app's own permissions |
| `taskRoleArn` | `devops-g3-task-role` | the running app's own permissions — scoped only to the 4 SSM messaging actions ECS Exec needs |
| `runtimePlatform.cpuArchitecture` | `X86_64` | must match the `--platform linux/amd64` build, or the task won't schedule |
| `portMappings[0].name` | `payment-3003` | this **named** port mapping is what Service Connect will resolve by name in Phase 3 |
| `healthCheck` | `curl -f http://localhost:3003/health \|\| exit 1`, interval 30s, timeout 5s, retries 3, startPeriod 10s | `startPeriod` gives gunicorn 10s to bind before the first check counts against it |
| `logConfiguration` | awslogs → `/ecs/devops-g3/payment`, region `us-west-1`, stream-prefix `ecs` | uses the already-created log group from the handover (see §1) |

**`OTEL_SDK_DISABLED=true` is set explicitly.** Found during local testing:
`common/tracing.py` exports spans via OTLP to `http://jaeger:4318` by
default, but Jaeger was retired to `archive/` and never replaced. Locally
this showed up as repeated `NameResolutionError` retries and one `/charge`
request whose logged `duration_ms` was ~15 seconds instead of ~50ms — the
batch span exporter was retrying synchronously in the request path before
giving up. Same thing happens on every request in the real ECS task.
`tracing.py` already respects this env var, so setting it is a one-line,
zero-risk fix. Remove it once a real tracing backend is deployed.

Register it, substituting in the image URI you just pushed:
```bash
sed "s#827478161993.dkr.ecr.us-west-1.amazonaws.com/devops-g3-payment:REPLACE_WITH_GIT_SHA#${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/devops-g3-payment:${SHA}#" \
  task-definition-payment.json > /tmp/task-def-filled.json

aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-def-filled.json \
  --region $REGION \
  --query "taskDefinition.taskDefinitionArn" --output text
```
Expected: an ARN like `arn:aws:ecs:us-west-1:827478161993:task-definition/devops-g3-payment:1`

---

## 7. ECS service

Get two subnets in different AZs:
```bash
SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  --query "Subnets[0:2].SubnetId" --output text | tr '\t' ',')
```

Check whether the service already exists before creating (avoids the
"Creation of service was not idempotent" error):
```bash
aws ecs describe-services --cluster $CLUSTER --services devops-g3-payment \
  --region $REGION --query "services[0].status" --output text
```

If it returns `ACTIVE`, the service already exists — skip straight to
§10 (checkpoint). Otherwise, create it:
```bash
aws ecs create-service \
  --cluster $CLUSTER \
  --service-name devops-g3-payment \
  --task-definition devops-g3-payment \
  --desired-count 1 \
  --launch-type FARGATE \
  --platform-version LATEST \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
  --enable-execute-command \
  --tags key=Project,value=devops-Ecommerce key=Group,value=group-3 key=Owner,value=payment-owner key=Environment,value=lab \
  --region $REGION \
  --query "service.serviceArn" --output text
```

Wait for it to stabilize (takes 1-3 minutes, prints nothing until done):
```bash
aws ecs wait services-stable --cluster $CLUSTER --services devops-g3-payment --region $REGION
```

**Shipping a new SHA later:** rebuild/tag/push a new image, register a new
task definition revision (§6), then:
```bash
aws ecs update-service --cluster $CLUSTER --service devops-g3-payment \
  --task-definition devops-g3-payment --region $REGION
```

---

## 8. Settings summary

```
cluster:                devops-g3-cluster
service-name:           devops-g3-payment
task-definition:        devops-g3-payment (family — always resolves to latest ACTIVE revision)
desired-count:          1
launch-type:            FARGATE
subnets:                2 default subnets, different AZs
security-groups:        devops-g3-payment-sg
assign-public-ip:       ENABLED   (lab only — outbound path to ECR/CloudWatch; no ALB yet to front it)
deployment circuit
  breaker + rollback:   both ENABLED — a bad deploy auto-rolls-back instead of
                         leaving the service stuck in a failed steady state
enable-execute-command: true
```

---

## 9. Order of operations (why this sequence matters)

```
pre-flight checks → ECR repo → build/tag/push → security group
   → register task definition (needs the pushed image URI)
   → create/update ECS service (needs the task def + the SG)
   → wait for service-stable → checkpoint verification
```

This mirrors the dependency chain in the source docs exactly: Track 1
(cluster + roles) must exist first, then image before task def, task def +
SG before service, service stable before checkpoint. Nothing here can be
safely reordered.

---

## 10. The five checkpoint criteria — command for each

**1. Task RUNNING:**
```bash
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-payment \
  --region $REGION --query "taskArns[0]" --output text)
TASK_ID=$(basename $TASK_ARN)
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --region $REGION \
  --query "tasks[0].lastStatus" --output text
```
Expected: `RUNNING`

**2. Container HEALTHY:**
```bash
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --region $REGION \
  --query "tasks[0].containers[?name=='payment'].healthStatus" --output text
```
Expected: `HEALTHY`. If you see `UNKNOWN`, wait ~40s (10s startPeriod + first
30s check interval) and re-run.

**3. CloudWatch log line visible:**
```bash
aws logs tail /ecs/devops-g3/payment --since 10m --region $REGION
```
Expected: JSON log lines, e.g. `health_check` events roughly every 30s.

**4. SHA visible via `/version` (through ECS Exec, no network exposure
needed):**
```bash
aws ecs execute-command --cluster $CLUSTER --task $TASK_ID \
  --container payment --region $REGION --interactive \
  --command "curl -s localhost:3003/version"
```
Expected: `{"service":"payment","version":"<sha>","status":"ok"}`. This has
to go through ECS Exec, not a laptop `curl`, because there's no ALB or
inbound SG rule yet in Phase 2 — that's correct architecture, not a
workaround.

**5. ECS Exec shell access:**
```bash
aws ecs execute-command --cluster $CLUSTER --task $TASK_ID \
  --container payment --region $REGION --interactive --command "/bin/sh"
```
Opens a live interactive shell inside the running container.

---

## 11. Real deployment log — issues actually hit and how they were fixed

Captured live during the first real deploy, in the order they came up. Add
these to the shared scar log — every one of these has a decent chance of
hitting Hunter or Joynce too, since the setup is nearly identical for
order/inventory.

1. **AWS CLI and Session Manager plugin weren't installed yet** on the
   operator's machine. Installed AWS CLI v2 via the official `.pkg`, then
   `aws configure` + `aws sts get-caller-identity` to confirm account
   `827478161993`.

2. **`docker push` timed out** (`context deadline exceeded`) even though the
   image had built successfully and `docker login` had reported
   `Login Succeeded`. Diagnosed by testing raw connectivity first —
   `curl -v https://<account>.dkr.ecr.us-west-1.amazonaws.com/v2/` returned a
   fast `401 Unauthorized`, confirming the network path to ECR was fine and
   the problem was local to Docker Desktop's own networking stack (common
   after the machine has been asleep or idle). **Fix:** restarted Docker
   Desktop fully, re-ran `docker login`, retried the push with no rebuild
   needed (image was already cached) — succeeded immediately. **Lesson:** a
   fast `401` from `curl` against the registry endpoint is the fastest way
   to separate "network problem" from "Docker problem."

3. **`CreateSecurityGroup` rejected the description string**:
   `InvalidParameterValue ... Character sets beyond ASCII are not supported`.
   The description text used an em dash (`—`) instead of a plain hyphen
   (`-`). AWS security group descriptions are ASCII-only. **Fix:** replaced
   `—` with `-`. **Lesson:** avoid smart-quotes/em-dashes/en-dashes in any
   AWS resource name, description, or tag value — they look identical to a
   hyphen in most editors but fail AWS's ASCII validation.

4. **`CreateService` failed with `Creation of service was not idempotent`**
   on a retry. This is AWS correctly refusing to create a duplicate — an
   earlier attempt (before the SG fix) had already succeeded in creating
   the service. **Diagnosed** with `describe-services` showing `ACTIVE` / 1
   / 1 — i.e. the service already existed and was healthy. **Lesson:** on a
   "not idempotent" or "already exists" error, always check current state
   with `describe-*` before assuming something is broken — it's often proof
   an earlier attempt actually worked.

5. **Checks 1-3 of the checkpoint passed cleanly on the first real run:**
   task `RUNNING`, container `HEALTHY`, and JSON log lines visible in
   CloudWatch every ~30 seconds from the `/health` probe — with no Jaeger
   retry noise in them, confirming the `OTEL_SDK_DISABLED=true` fix (§6) is
   working correctly in the deployed task, not just locally.

6. **Check 4 failed with `SessionManagerPlugin is not found`** — flagged
   early in §2 but not installed before running the checkpoint. **Fix:**
   installed via `brew install --cask session-manager-plugin`, confirmed
   with `session-manager-plugin` printing version info, then re-ran the
   check 4 command. **Lesson:** don't treat a pre-flight *warning* as safe
   to ignore — this one silently blocks two of the five checkpoint criteria.