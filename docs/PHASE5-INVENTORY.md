# Phase 5 — inventory delivery pipeline

**Service:** inventory | **Port:** 3002 | **Desired count:** 1
**Region:** us-west-1 | **Account:** 827478161993 | **Cluster:** devops-g3-cluster

Goal: a merge to `main` that touches `inventory/` is the last manual action. The
pipeline builds, tags with the commit SHA, pushes to ECR, and deploys a new task
definition revision with no further intervention.

| | |
|---|---|
| ECR repo | `devops-g3-inventory` |
| Container name | `inventory` (must match the task-def container name exactly) |
| Task-def family | `devops-g3-inventory` |
| ECS service | `devops-g3-inventory` |
| CodeBuild project | `devops-g3-inventory-build` |
| Pipeline | `devops-g3-inventory-pipeline` |
| Path filter | `inventory/**`, `buildspecs/inventory.yml` |

**What is different from order:** inventory has no ALB and no target group, so the
deployed SHA cannot be checked with a public curl. Verification is via ECS Exec
(`curl localhost:3002/version`) from inside the running task. That needs
`session-manager-plugin` installed locally.

---

## 0. Prerequisites — confirm before building anything

These are platform-owned (Lwam and Minage). All three must pass or the pipeline
cannot be created.

```bash
export AWS_PAGER="" AWS_REGION=us-west-1

aws codeconnections list-connections --region $AWS_REGION \
  --query 'Connections[].{name:ConnectionName,status:ConnectionStatus}' --output table

aws iam get-role --role-name devops-g3-codebuild-role   --query 'Role.Arn' --output text
aws iam get-role --role-name devops-g3-codepipeline-role --query 'Role.Arn' --output text
```

The connection must read **`AVAILABLE`**. `PENDING` means it was created but never
authorized in GitHub — the source stage will fail with an unhelpful error, so fix it
before wiring anything up.

---

## 1. Buildspec — done

`buildspecs/inventory.yml` is finalized and structurally identical to Hunter's merged
`buildspecs/order.yml`; only `ECR_REPO`, `CONTAINER_NAME` and `SERVICE_DIR` differ.

Two things it fixes over the Phase 2 stub, both of which would break in a pipeline:

- **`SHA` comes from `CODEBUILD_RESOLVED_SOURCE_VERSION`, not `git rev-parse`.**
  CodeConnections hands the source to CodeBuild as a zip artifact with no `.git`
  directory, so `git rev-parse` fails and the tag comes out empty.
- **Account is derived at runtime** with `sts get-caller-identity` rather than read
  from an `AWS_ACCOUNT_ID` env var that has to be set on every project.

It also validates the source (`py_compile`, or pytest if a `tests/` dir appears) before
building, so a broken commit fails in CodeBuild rather than three minutes later at the
ECS health check.

If the file is ever lost, this is the content:

```yaml
version: 0.2
env:
  variables:
    ECR_REPO: devops-g3-inventory
    CONTAINER_NAME: inventory
    SERVICE_DIR: inventory

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

---

## 2. CodeBuild project — `devops-g3-inventory-build`

Console: CodeBuild → Create build project.

| Setting | Value |
|---|---|
| Project name | `devops-g3-inventory-build` |
| Source | GitHub via the shared connection `devops-g3-connection` |
| Repository | `hunterachieng/group-3-devops-networking` |
| Branch | `main` |
| Environment image | Managed, Amazon Linux, standard runtime |
| **Privileged** | **ENABLED** |
| Service role | existing — `devops-g3-codebuild-role` |
| Buildspec | Use a buildspec file → `buildspecs/inventory.yml` |
| Logs | CloudWatch enabled |

**Privileged mode is the one that bites.** `docker build` needs the Docker daemon;
without it the build fails with "Cannot connect to the Docker daemon". It cannot be
changed per-build — it is a project setting.

Verify:
```bash
aws codebuild batch-get-projects --names devops-g3-inventory-build --region $AWS_REGION \
  --query 'projects[0].{privileged:environment.privilegedMode,buildspec:source.buildspec,role:serviceRole}'
```
→ `privileged: true` and `buildspec: buildspecs/inventory.yml`

---

## 3. Pipeline — `devops-g3-inventory-pipeline`

Console: CodePipeline → Create pipeline → **V2** (V1 cannot do path-filtered triggers).

**Source stage**
- Provider: GitHub (via CodeConnections), connection `devops-g3-connection`
- Repository `hunterachieng/group-3-devops-networking`, branch `main`
- Trigger: filter on **file paths** — include `inventory/**` and `buildspecs/inventory.yml`

The path filter is what stops a change to order or payment from rebuilding inventory.
Without it all three pipelines fire on every merge, which the plan explicitly calls out.

**Build stage**
- Provider: CodeBuild, project `devops-g3-inventory-build`

**Deploy stage**
- Provider: Amazon ECS
- Cluster `devops-g3-cluster`, service `devops-g3-inventory`
- Image definitions file: `imagedefinitions.json`

The ECS deploy action takes the service's **current** task definition, swaps in the
image URI from `imagedefinitions.json`, registers that as a new revision, and rolls it
out — honouring the circuit breaker and automatic rollback already enabled on the
service. It does not read `infra/inventory/taskdef.json`; after Phase 5 that file is
reference only, and any change to the health check, roles, or resources has to be
applied by registering a revision manually.

Verify:
```bash
aws codepipeline get-pipeline --name devops-g3-inventory-pipeline --region $AWS_REGION \
  --query 'pipeline.stages[].{stage:name,action:actions[0].actionTypeId.provider}' --output table
```

---

## 4. Prove it — hands-off deploy

Make a small visible change inside `inventory/` (a log string is enough), open a PR, get
one approval, merge. **No manual action after the merge.**

```bash
# 1. the pipeline started on its own
aws codepipeline list-pipeline-executions --pipeline-name devops-g3-inventory-pipeline \
  --region $AWS_REGION --max-items 1 \
  --query 'pipelineExecutionSummaries[0].{status:status,trigger:trigger.triggerType,started:startTime}'
```
→ `trigger: Webhook`, not `StartPipelineExecution` (which would mean a manual start)

```bash
# 2. the image exists at the merge SHA
export SHA=<short sha of the merge commit>
aws ecr describe-images --repository-name devops-g3-inventory \
  --image-ids imageTag=$SHA --region $AWS_REGION --query 'imageDetails[0].imageTags'
```

```bash
# 3. a new task-def revision was registered and rolled out
aws ecs describe-services --cluster devops-g3-cluster --services devops-g3-inventory \
  --region $AWS_REGION \
  --query 'services[0].{td:taskDefinition,running:runningCount,deployments:deployments[].{status:status,rollout:rolloutState}}'
```

```bash
# 4. the running task serves the new SHA  (inventory has no ALB — exec is the only way)
export TASK=$(aws ecs list-tasks --cluster devops-g3-cluster --service-name devops-g3-inventory \
  --region $AWS_REGION --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster devops-g3-cluster --task $TASK \
  --container inventory --interactive --command "/bin/sh" --region $AWS_REGION
# inside the task:
curl -s localhost:3002/version
```
→ `{"service":"inventory","status":"ok","version":"<merge SHA>"}`

```bash
# 5. only YOUR pipeline ran — the path filter works
aws codepipeline list-pipeline-executions --pipeline-name devops-g3-order-pipeline \
  --region $AWS_REGION --max-items 1 --query 'pipelineExecutionSummaries[0].startTime'
```
→ older than your merge

Step 4 also closes **scar 5** from the Phase 2 runbook: the pipeline builds from the
merged commit, so for the first time the image tag and the running code genuinely match.

---

## 5. Evidence to capture

- [ ] PR link + approval
- [ ] Merge commit SHA
- [ ] Pipeline execution showing an automatic (webhook) trigger
- [ ] CodeBuild log showing the inventory build
- [ ] `describe-images` output for the SHA tag
- [ ] `imagedefinitions.json` contents from the build log
- [ ] New ECS task-definition revision number
- [ ] `curl localhost:3002/version` via ECS Exec returning the merge SHA
- [ ] Order/payment pipelines untriggered (path filter proof)

---

## Checklist

- [x] `buildspecs/inventory.yml` finalized
- [ ] Platform prerequisites confirmed (connection AVAILABLE, both roles exist)
- [ ] CodeBuild `devops-g3-inventory-build` created, privileged ON
- [ ] Pipeline `devops-g3-inventory-pipeline` created (V2, path-filtered)
- [ ] Hands-off deploy proven, new SHA confirmed via ECS Exec

---

## Scar candidates for this phase

Record symptom → hypothesis → evidence → cause → repair → prevention, **before**
repairing. Continues numbering from `PHASE4-INVENTORY.md` (currently at 12).

| Likely failure | Symptom |
|---|---|
| Privileged mode off | "Cannot connect to the Docker daemon" in the build log |
| CodeBuild role missing ECR perms | `denied: User is not authorized to perform ecr:PutImage` |
| CodePipeline cannot pass the ECS roles | Deploy stage fails with an `iam:PassRole` AccessDenied |
| Connection not authorized | Source stage fails immediately, connection shows `PENDING` |
| Wrong `CONTAINER_NAME` | Deploy stage fails: the name in `imagedefinitions.json` matches no container |
| Missing path filter | A merge to `order/` rebuilds and redeploys inventory |
| `git rev-parse` left in the buildspec | Empty image tag, or the build fails at the tag step |
