# Phase 5 — order delivery pipeline

**Service:** order | **Port:** 3001 | **Desired count:** 2
**Region:** us-west-1 | **Account:** 827478161993 | **Cluster:** devops-g3-cluster

Goal: a merge to `main` is the last manual action. The pipeline builds, tags with the
commit SHA, pushes to ECR, and deploys a new task-definition revision with no further
intervention — and if that revision is unhealthy, ECS rolls it back on its own.

| | |
|---|---|
| ECR repo | `devops-g3-order` |
| Container name | `order` (must match the task-def container name exactly) |
| Task-def family | `devops-g3-order` |
| ECS service | `devops-g3-order` |
| CodeBuild project | `devops-g3-order-build` |
| Pipeline | `devops-g3-order-pipeline` |
| ALB | `devops-g3-alb` → target group `devops-g3-order-tg` (`/health`) |

**What is different from inventory/payment:** order is the only ALB-registered service,
so the deployed SHA is visible over the public internet with
`curl "http://$ALB_DNS/version"`. That makes it the natural service to prove both gates
on — the deploy and the rollback are both observable without ECS Exec.

Two graded gates:

- **Gate 3A — hands-off deploy.** Merge to `main` → pipeline auto-triggers → build →
  deploy → new SHA visible at the ALB `/version`.
- **Gate 3B — auto-rollback.** Merge a revision whose health check fails → ECS
  deployment circuit breaker aborts the rollout and reverts to the last good revision →
  the ALB keeps serving throughout.

---

## 0. Prerequisites — confirm before building anything

Platform-owned (Lwam and Minage). All must pass or the pipeline cannot be created.

```bash
export AWS_PAGER="" AWS_REGION=us-west-1

aws codeconnections list-connections --region $AWS_REGION \
  --query 'Connections[].{name:ConnectionName,status:ConnectionStatus}' --output table

aws iam get-role --role-name devops-g3-codebuild-role   --query 'Role.Arn' --output text
aws iam get-role --role-name devops-g3-codepipeline-role --query 'Role.Arn' --output text
```

- Connection `devops-g3-connection` must read **`AVAILABLE`**
  (ARN `arn:aws:codeconnections:us-west-1:827478161993:connection/d92ced2b-936a-453d-9828-17f5e9c67e42`).
- Artifact bucket is shared and already exists:
  `devops-g3-codepipeline-artifacts-827478161993-us-west-1` — do **not** create a new one.
- The circuit breaker must already be enabled on `devops-g3-order` (Phase 2/3) — Gate 3B
  depends on it. Confirm:
  ```bash
  aws ecs describe-services --cluster devops-g3-cluster --services devops-g3-order \
    --region $AWS_REGION \
    --query 'services[0].deploymentConfiguration.deploymentCircuitBreaker'
  ```
  → `{"enable": true, "rollback": true}`

> **`AVAILABLE` is necessary but not sufficient.** See scar 5 — an `AVAILABLE` connection
> proves CodeConnections can *read* the repo, but auto-triggering also needs the GitHub
> **App** to be *installed* on the account that owns the repo. That is a separate switch.

---

## 1. Buildspec — done

`buildspecs/order.yml` is finalized. Same structure as inventory/payment; only
`ECR_REPO`, `CONTAINER_NAME` and `SERVICE_DIR` differ.

Two things it fixes over the Phase 2 stub, both of which break in a pipeline:

- **`SHA` comes from `CODEBUILD_RESOLVED_SOURCE_VERSION`, not `git rev-parse`.**
  CodeConnections hands the source to CodeBuild as a zip artifact with no `.git`
  directory, so `git rev-parse` fails and the tag comes out empty.
- **Account is derived at runtime** with `sts get-caller-identity` rather than read from
  an `AWS_ACCOUNT_ID` env var that has to be set on every project.

`order/` has no `tests/` directory, so the source-validation step falls back to
`py_compile` — a broken commit fails in CodeBuild rather than three minutes later at the
ECS health check.

If the file is ever lost, this is the content:

```yaml
version: 0.2
env:
  variables:
    ECR_REPO: devops-g3-order
    CONTAINER_NAME: order
    SERVICE_DIR: order

phases:
  pre_build:
    commands:
      - AWS_REGION=${AWS_DEFAULT_REGION:-us-west-1}
      - ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
      - REPO=$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO
      - SHA=$(echo ${CODEBUILD_RESOLVED_SOURCE_VERSION:-dev} | cut -c1-7)
      - IMAGE_URI=$REPO:$SHA
      - echo "Building $CONTAINER_NAME  SHA=$SHA  ->  $IMAGE_URI"
      - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
  build:
    commands:
      - echo Validating source...
      - if [ -d "$SERVICE_DIR/tests" ]; then pip install -r $SERVICE_DIR/requirements.txt && python -m pytest $SERVICE_DIR/tests; else python -m py_compile $SERVICE_DIR/app.py; fi
      - echo Building image for linux/amd64...
      - docker build --platform linux/amd64 --build-arg GIT_SHA=$SHA -t $IMAGE_URI ./$SERVICE_DIR
  post_build:
    commands:
      - docker push $IMAGE_URI
      - printf '[{"name":"%s","imageUri":"%s"}]' "$CONTAINER_NAME" "$IMAGE_URI" > imagedefinitions.json
      - cat imagedefinitions.json
      - echo Build complete. Pushed $IMAGE_URI

artifacts:
  files:
    - imagedefinitions.json
```

The `--build-arg GIT_SHA=$SHA` is what makes the gates provable: the Dockerfile bakes it
into `GIT_SHA`, `order/app.py` reads it (`GIT_SHA = os.environ.get("GIT_SHA", "dev")`),
and `/version` and `/health` echo it back — so the SHA the ALB reports is the SHA that
was built.

---

## 2. CodeBuild project — `devops-g3-order-build`

| Setting | Value |
|---|---|
| Project name | `devops-g3-order-build` |
| Source | GitHub via the shared connection `devops-g3-connection` |
| Repository | `hunterachieng/group-3-devops-networking` |
| Branch | `main` |
| Environment image | Managed, Amazon Linux, standard runtime |
| **Privileged** | **ENABLED** |
| Service role | existing — `devops-g3-codebuild-role` |
| Buildspec | Use a buildspec file → `buildspecs/order.yml` |
| Logs | CloudWatch, log group **`/aws/codebuild/devops-g3-order`** |

Two settings bite here:

- **Privileged mode.** `docker build` needs the Docker daemon; without it the build
  fails with "Cannot connect to the Docker daemon". It cannot be changed per-build.
- **Log group must be under `/aws/codebuild/*`** — see scar 2.

Verify:
```bash
aws codebuild batch-get-projects --names devops-g3-order-build --region $AWS_REGION \
  --query 'projects[0].{privileged:environment.privilegedMode,buildspec:source.buildspec,role:serviceRole,logs:logsConfig.cloudWatchLogs.groupName}'
```
→ `privileged: true`, `buildspec: buildspecs/order.yml`, `logs: /aws/codebuild/devops-g3-order`

---

## 3. Pipeline — `devops-g3-order-pipeline`

CodePipeline → Create pipeline → **V2** (V1 cannot do connection-based auto-triggers).

**Source stage**
- Provider: GitHub (via CodeConnections), connection `devops-g3-connection`
- Repository `hunterachieng/group-3-devops-networking`, branch `main`
- **`DetectChanges: true`** — this is what creates the webhook (see scar 4)
- Trigger: filter on branch `main` only. **Do not add a `filePaths` filter** on this
  pipeline (see scar 6).

**Build stage**
- Provider: CodeBuild, project `devops-g3-order-build`

**Deploy stage**
- Provider: Amazon ECS
- Cluster `devops-g3-cluster`, service `devops-g3-order`
- Image definitions file: `imagedefinitions.json`

The ECS deploy action takes the service's **current** task definition, swaps in the image
URI from `imagedefinitions.json`, registers that as a new revision, and rolls it out —
honouring the circuit breaker and automatic rollback already enabled on the service. It
does **not** read `infra/order/task-def.json`; after Phase 5 that file is reference only,
and any change to the health check, roles, or resources has to be applied by registering
a revision manually.

Verify:
```bash
aws codepipeline get-pipeline --name devops-g3-order-pipeline --region $AWS_REGION \
  --query 'pipeline.stages[].{stage:name,action:actions[0].actionTypeId.provider}' --output table

# confirm the webhook is armed and NOT path-filtered
aws codepipeline get-pipeline --name devops-g3-order-pipeline --region $AWS_REGION \
  --query 'pipeline.triggers[0].gitConfiguration.push[0]'
```
→ `branches.includes: ["main"]`, and **no** `filePaths` key.

---

## 4. Gate 3A — prove hands-off deploy

Make a small visible change inside `order/` (a marker string in `/version` is enough),
open a PR, get one approval, merge. **No manual action after the merge.**

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers --names devops-g3-alb \
  --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text)

# 1. the pipeline started on its own — trigger type is a webhook, not a manual start
aws codepipeline list-pipeline-executions --pipeline-name devops-g3-order-pipeline \
  --region $AWS_REGION \
  --query 'pipelineExecutionSummaries[0].{status:status,trigger:trigger.triggerType,started:startTime}'
```
→ `trigger: WebhookV2` (a manual start would read `StartPipelineExecution`)

```bash
# 2. wait for the deploy, then the ALB serves the new SHA
aws codepipeline get-pipeline-state --name devops-g3-order-pipeline --region $AWS_REGION \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table

curl -s "http://$ALB_DNS/version"
```
→ `{"marker":"gate3a-hands-off-5","service":"order","status":"ok","version":"41eb453"}`
— the `version` changed from the previous SHA with zero manual deploy steps. The QA
run deployed PR **#53** ("feat: test deployment", 3 approvals), which produced SHA
`41eb453` on task-def `devops-g3-order:14`.

Captured in [phase5-evidence/A5-version.txt](../phase5-evidence/A5-version.txt),
[phase5-evidence/A1-trigger.txt](../phase5-evidence/A1-trigger.txt) (WebhookV2),
[phase5-evidence/A0-pr.txt](../phase5-evidence/A0-pr.txt) (PR + approvals),
[phase5-evidence/A3-ecr.txt](../phase5-evidence/A3-ecr.txt) (ECR tag) and
[phase5-evidence/A6-imagedefs.txt](../phase5-evidence/A6-imagedefs.txt)
(`[{"name":"order","imageUri":"…/devops-g3-order:41eb453"}]`).

---

## 5. Gate 3B — prove auto-rollback

Intentionally break the health check, merge, and watch ECS refuse to finish the rollout.

**The break** — `order/app.py` `/health` temporarily returns 500 (on a short-lived branch
`gate3b/health-fail`):

```python
@app.get("/health")
def health():
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried",
              request_id=rid, path="/health", outcome="fail")
    return jsonify(status="unhealthy", service=SERVICE_NAME, version=GIT_SHA), 500
```

Merge it. The pipeline builds and deploys the bad revision (task-def `:15`). Then:

```bash
# new tasks never go healthy: runningCount stays 0 on the bad deployment,
# while the last good deployment (:14) keeps runningCount 2
aws ecs describe-services --cluster devops-g3-cluster --services devops-g3-order \
  --region $AWS_REGION \
  --query 'services[0].deployments[].{td:taskDefinition,rollout:rolloutState,reason:rolloutStateReason,running:runningCount,failed:failedTasks}'
```
→ the bad deployment `:15` reaches `rolloutState: FAILED` with reason *"ECS deployment
circuit breaker: tasks failed to start"* (4 failed tasks), ECS rolls back with *"rolling
back to deployment ecs-svc/2271940597359048268"*, and the good `:14` deployment returns to
`PRIMARY / COMPLETED / running 2`.

```bash
# the ALB never stopped serving the good version during the failed rollout
curl -s "http://$ALB_DNS/version"
```
→ still `version: 41eb453`, status ok — the bad `:15` never registered to the ALB.

**User impact** — a `/health` curl loop over the rollout window recorded **994/1013 =
98.1%** `200`s and 19 momentary `status=000` blips during target-registration churn, with
**no sustained outage** (`:14` held `running: 2` throughout).

Evidence:
- [phase5-evidence/B1-deployments.txt](../phase5-evidence/B1-deployments.txt) — `:15` FAILED + circuit-breaker rollback reason
- [phase5-evidence/B2-events.txt](../phase5-evidence/B2-events.txt) — ECS service events (failed container health checks + rolling back)
- [phase5-evidence/B3-targets.txt](../phase5-evidence/B3-targets.txt) — good ALB targets stayed healthy
- [phase5-evidence/B4-restored.txt](../phase5-evidence/B4-restored.txt) — service restored to `:14`
- [phase5-evidence/B5-version.txt](../phase5-evidence/B5-version.txt) — recovery: `/version` = `41eb453`, targets `healthy healthy`
- [phase5-evidence/B6-traffic.txt](../phase5-evidence/B6-traffic.txt) — traffic loop (98.1% availability during rollback)

**Restore health after the gate.** Revert `/health` to `200`/`ok`, merge, and the
pipeline auto-deploys a clean healthy revision:

```python
@app.get("/health")
def health():
    rid = request_id_from(request)
    log_event(log, "health_check", "health endpoint queried",
              request_id=rid, path="/health", outcome="ok")
    return jsonify(status="ok", service=SERVICE_NAME, version=GIT_SHA), 200
```

---

## 6. Evidence captured

The QA run (2026-07-24) re-captured everything into `phase5-evidence/` — Gate 3A **9/9**,
Gate 3B **7/7**.

- [x] PR link + approval — PR #53, 3 approvals (`A0-pr.txt`)
- [x] Merge commit SHA (`41eb453`)
- [x] Pipeline execution showing `WebhookV2` trigger — `A1-trigger.txt`
- [x] CodeBuild built the correct service, SUCCEEDED — `A2-build.txt`
- [x] SHA-tagged image in ECR — `A3-ecr.txt`
- [x] `imagedefinitions.json` = `[{"name":"order","imageUri":"…:41eb453"}]` — `A6-imagedefs.txt`
- [x] New ECS revision `:14` deployed — `A4-deploy.txt`
- [x] ALB `/version` returning the merge SHA — `A5-version.txt`
- [x] Circuit-breaker: `:15` FAILED + rollback — `B1-deployments.txt`, `B2-events.txt`
- [x] ALB stayed on the good version during rollback — `B3-targets.txt`, `B5-version.txt`
- [x] Restored known-good revision `:14` — `B4-restored.txt`
- [x] User impact 98.1% during rollback — `B6-traffic.txt`
- [x] `/health` restored to 200 and re-merged clean — main healthy on SHA `606c058` (`:16`)

---

## Checklist

- [x] `buildspecs/order.yml` finalized
- [x] Platform prerequisites confirmed (connection AVAILABLE, both roles exist, circuit breaker on)
- [x] CodeBuild `devops-g3-order-build` created, privileged ON, log group `/aws/codebuild/devops-g3-order`
- [x] Pipeline `devops-g3-order-pipeline` created (V2, `DetectChanges:true`, no `filePaths` filter)
- [x] Gate 3A hands-off deploy proven (WebhookV2 → new SHA `41eb453` at ALB `/version`)
- [x] Gate 3B auto-rollback proven (bad `:15` aborted, reverted to good `:14`, 98.1% availability)
- [x] `/health` restored, main healthy on SHA `606c058`

---

## Scars

Recorded symptom → cause → repair → prevention.

### Scar 1 — zsh `:r` ate `:role` in the role ARN
- **Symptom:** CodeBuild "Invalid service role" / a role ARN that read
  `827478161993ole/...`.
- **Cause:** `arn:aws:iam::$ACCOUNT:role/...` in zsh — `$ACCOUNT:r` is the `:r`
  (strip-extension) history modifier and it swallowed `:role`.
- **Repair / prevention:** always brace the variable — `${ACCOUNT}:role`.

### Scar 2 — CodeBuild log group must be under `/aws/codebuild/*`
- **Symptom:** build dies immediately with `CLIENT_ERROR ... not authorized to perform
  logs:CreateLogStream`, and the log group comes back null so there is nothing to read.
- **Cause:** the project was pointed at a custom log group `/codebuild/devops-g3-order`;
  the CodeBuild role's logs policy is scoped to `/aws/codebuild/*`.
- **Repair:** `update-project` to log group `/aws/codebuild/devops-g3-order`.
- **Prevention:** keep CodeBuild logs under the `/aws/codebuild/` prefix.

### Scar 3 — pipeline builds the buildspec from `main`, not the local tree
- **Symptom:** the build ran the *old* stub buildspec (unset `$AWS_ACCOUNT_ID` →
  empty ECR host `.dkr.ecr...` → DNS failure in PRE_BUILD), even though the local file was
  fixed.
- **Cause:** the buildspec fix was committed only on `feature/order-deployment`; the
  pipeline reads `buildspecs/order.yml` from the merged `main`.
- **Repair / prevention:** commit + push + **merge** buildspec changes to `main` before
  expecting them to take effect.

### Scar 4 — `DetectChanges:false` disables the webhook entirely
- **Symptom:** merges to `main` never triggered the pipeline; every execution was
  `StartPipelineExecution` / `CreatePipeline`, never a webhook.
- **Cause:** the source action had `DetectChanges:false`. The pipeline-level `triggers`
  block only *filters* delivered events — it does not *create* the webhook.
- **Repair / prevention:** set `DetectChanges:true` on the source action (keep the
  `triggers` block for branch scoping).

### Scar 5 — GitHub App OAuth-authorized but not *installed* (root cause of no auto-trigger)
- **Symptom:** config was perfect (V2, `DetectChanges:true`, `branches:[main]`, connection
  `AVAILABLE`) and merges *did* land on `main`, yet no execution was ever a webhook — only
  `CreatePipeline` / `StartPipelineExecution`. Even delete-and-recreate of the pipeline
  did not fix it.
- **Cause:** the "AWS Connector for GitHub" app was only *OAuth-authorized* on the account,
  not *installed* as a GitHub App on the repo owner. Source **pulls** work (token read
  access) but push **events** (webhooks) require the App installation. Hunter's IAM
  permissions boundary also denied `codeconnections:StartOAuthHandshake` /
  `ListConnections` / `CreateConnection`, so he could not self-service the install.
- **Repair:** platform admin installed + bound the app to `hunterachieng` (now shows in
  both "Installed GitHub Apps" and OAuth-authorized). Merge to `main` then fired trigger
  type **`WebhookV2`**.
- **Prevention:** an `AVAILABLE` connection is not proof of event delivery. Confirm the
  App is *installed* on the repo owner (`github.com/settings/installations`), not merely
  authorized. Diagnose with
  `gh api /user/installations --jq '.installations[]|[.id,.app_slug]|@tsv'`.

### Scar 6 — `filePaths` trigger filter silently drops merge-commit pushes
- **Symptom:** even with `DetectChanges:true`, merges to `main` did not auto-trigger while
  the pipeline had `triggers.gitConfiguration.push[].filePaths=[order/**, buildspecs/order.yml]`.
  Confirmed on an idle pipeline, so not a busy-race.
- **Cause:** GitHub "Create a merge commit" push events deliver an empty/merge-only file
  list, so the `filePaths` filter matched nothing and the trigger was dropped.
- **Repair:** strip `filePaths` from the trigger (keep `branches:[main]` only) via
  get-pipeline → pop `filePaths` → update-pipeline.
- **Prevention:** for order, don't path-filter at the pipeline trigger. (Order is the only
  service on this pipeline, so there is nothing to filter out anyway.)

### Scar 7 — recurring merge gap: pushing the branch is not merging the PR
- **Symptom:** "the webhook isn't firing" — but `main` had not actually advanced.
- **Cause:** `git push origin feature/order-deployment` pushes the branch; the pipeline
  watches `main`, which only advances when the PR is merged.
- **Prevention:** before blaming the webhook, verify `git log origin/main --oneline -1`
  actually advanced to the new commit.

### Scar 8 — superseded runs on a busy pipeline
- **Symptom:** an execution showed `Cancelled` / a webhook event appeared to be "lost".
- **Cause:** firing `start-pipeline-execution` twice in quick succession cancels the older
  run (superseded), and a webhook arriving while a run is `InProgress` can be dropped.
- **Prevention:** run clean gate tests on an **idle** pipeline, with no manual starts.

### Scar 9 — evidence files are untracked and vanish
- **Symptom:** the whole `phase5-evidence/` directory came up empty at QA time; every
  capture from the original gate runs was gone.
- **Cause:** the evidence files were never committed (untracked / gitignored), so a branch
  switch / clean wiped them. Gate 3B's ECS **service events** had also scrolled off history
  after the intervening healthy deploys, so that evidence could not be reconstructed.
- **Repair:** re-ran both gates from scratch and re-captured to `phase5-evidence/`.
- **Prevention:** commit evidence immediately, or capture it somewhere tracked — ECS
  service events are transient (~100 entries) and cannot be recovered later.

### Scar 10 — env vars do not cross terminals
- **Symptom:** the second-terminal traffic loop returned `status=000` with ~0.003s
  timings for every request during the rollback test.
- **Cause:** `ALB_DNS` (and the other session exports) were only set in terminal 1;
  a new terminal starts with an empty environment, so the loop hit `http:///health`.
- **Prevention:** re-run the full `export …` session-setup block at the top of **every**
  new terminal before using `$ALB_DNS`/`$TG_ARN`; `echo "ALB_DNS=$ALB_DNS"` to confirm
  it is non-empty first.
