# Runbook — Order Service (Phase 2, ECS Fargate)

**Owner:** Hunter | **Service:** order | **Port:** 3001
**Cluster:** `devops-g3-cluster` | **Region:** `us-west-1` | **Account:** `827478161993`

Phase 2 goal: order runs as an isolated Fargate task — healthy, logging to
CloudWatch, SHA visible on `/version`, accessible via ECS Exec. No ALB or
Service Connect yet (Phase 3).

---

## Quick reference

```
ECR repo:        827478161993.dkr.ecr.us-west-1.amazonaws.com/devops-g3-order
Task def family: devops-g3-order
ECS service:     devops-g3-order
Security group:  devops-g3-order-sg
Log group:       /ecs/devops-g3/order
Execution role:  arn:aws:iam::827478161993:role/devops-g3-execution-role
Task role:       arn:aws:iam::827478161993:role/devops-g3-task-role
```

---

## 1. Prerequisites

```bash
brew install awscli
brew install --cask session-manager-plugin
aws sts get-caller-identity --region us-west-1   # must return account 827478161993
```

Set shell variables (re-run in every new terminal):

```bash
export AWS_REGION=us-west-1
export ACCOUNT=827478161993
export CLUSTER=devops-g3-cluster
export ECR_REPO=devops-g3-order
export REPO_URI=$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO
export AWS_PAGER=""   # stop JSON output opening in less
```

---

## 2. Build and push a new image

Run from the repo root. `SHA` must be the git commit SHA — never `latest`.

```bash
export SHA=$(git rev-parse --short HEAD)

# Authenticate Docker to ECR
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
    $ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

# Build for linux/amd64 (required for Fargate — fails with exec-format error on arm)
docker build --platform linux/amd64 --build-arg GIT_SHA=$SHA \
  -t $REPO_URI:$SHA ./order

docker push $REPO_URI:$SHA
```

---

## 3. Register a new task definition revision

Inject the SHA into the template and register:

```bash
export SHA=$(git rev-parse --short HEAD)
sed "s|REPLACE_WITH_SHA|$SHA|" infra/order/task-def.json > /tmp/order-task-def.json
aws ecs register-task-definition \
  --cli-input-json file:///tmp/order-task-def.json \
  --region $AWS_REGION --no-cli-pager
```

Confirm registration:

```bash
aws ecs describe-task-definition --task-definition devops-g3-order \
  --query 'taskDefinition.{family:family,rev:revision,image:containerDefinitions[0].image}' \
  --output table --region $AWS_REGION --no-cli-pager
```

---

## 4. Deploy — update the ECS service to the latest task def

```bash
aws ecs update-service \
  --cluster $CLUSTER \
  --service devops-g3-order \
  --task-definition devops-g3-order \
  --region $AWS_REGION --no-cli-pager
```

Watch rollout (wait for `running=2, pending=0`):

```bash
aws ecs describe-services --cluster $CLUSTER --services devops-g3-order \
  --query 'services[0].{running:runningCount,pending:pendingCount,desired:desiredCount}' \
  --output table --region $AWS_REGION --no-cli-pager
```

---

## 5. Phase 2 checkpoint verification

### Get a running task ARN

```bash
export TASK=$(aws ecs list-tasks --cluster $CLUSTER \
  --service-name devops-g3-order \
  --query 'taskArns[0]' --output text --region $AWS_REGION)
echo $TASK
```

### (1+2) Task RUNNING and container HEALTHY

```bash
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --region $AWS_REGION \
  --query 'tasks[0].{status:lastStatus,health:healthStatus}' \
  --output table --no-cli-pager
```

Expected: `status=RUNNING`, `health=HEALTHY`. If health is `UNKNOWN`, wait
30 s for the first health-check interval and rerun.

### (3) CloudWatch log line visible

```bash
aws logs tail /ecs/devops-g3/order --since 5m --region $AWS_REGION
```

### (4+5) SHA on /version and ECS Exec

```bash
aws ecs execute-command --cluster $CLUSTER --task $TASK \
  --container order --interactive --command "/bin/sh" --region $AWS_REGION
```

Inside the shell:

```sh
curl -s localhost:3001/version   # {"service":"order","version":"<sha>","status":"ok"}
curl -s localhost:3001/health    # {"service":"order-service","status":"ok","version":"<sha>"}
exit
```

---

## 6. Logs

Tail live logs:

```bash
aws logs tail /ecs/devops-g3/order --follow --region $AWS_REGION
```

Query last 30 minutes (pipe through `jq` for readable JSON):

```bash
aws logs filter-log-events \
  --log-group-name /ecs/devops-g3/order \
  --start-time $(date -v-30M +%s000) \
  --region $AWS_REGION --no-cli-pager \
  | jq -r '.events[].message | fromjson | "\(.timestamp) [\(.level)] \(.event) \(.message)"'
```

---

## 7. Troubleshooting

### Task not reaching RUNNING

```bash
aws ecs describe-services --cluster $CLUSTER --services devops-g3-order \
  --query 'services[0].events[0:5]' --region $AWS_REGION --no-cli-pager
```

| Event message | Likely cause | Fix |
|---|---|---|
| `CannotPullContainerError` | ECR auth or wrong image URI | Re-run ECR login; verify `$SHA` in task def matches pushed image |
| `ResourceInitializationError` | Execution role missing ECR/logs permissions | Check `devops-g3-execution-role` has `AmazonECSTaskExecutionRolePolicy` |
| Task stops immediately | App crash at startup | Check CloudWatch logs for Python traceback |

### Container RUNNING but health UNHEALTHY

```bash
# Exec in and test the health endpoint directly
aws ecs execute-command --cluster $CLUSTER --task $TASK \
  --container order --interactive --command "/bin/sh" --region $AWS_REGION
# then: curl -v localhost:3001/health
```

Common causes:
- App bound to `127.0.0.1` instead of `0.0.0.0` — health check cannot reach it. Verify `BIND_HOST=0.0.0.0` in the Dockerfile ENV.
- Wrong port — check `containerPort` in task def matches gunicorn bind port (3001).
- curl not in the image — rebuild with the `apt-get install curl` layer present.

### ECS Exec — SessionManagerPlugin error

```bash
# Confirm the plugin is installed
session-manager-plugin --version

# Confirm ECS Exec is enabled on the service
aws ecs describe-services --cluster $CLUSTER --services devops-g3-order \
  --query 'services[0].enableExecuteCommand' --region $AWS_REGION --no-cli-pager

# Confirm task role has SSM messaging permissions
aws iam get-role-policy \
  --role-name devops-g3-task-role \
  --policy-name devops-g3-ecs-exec-policy --no-cli-pager
```

### Circuit breaker triggered — service rolled back

```bash
aws ecs describe-services --cluster $CLUSTER --services devops-g3-order \
  --query 'services[0].deployments' --region $AWS_REGION --no-cli-pager
```

Check the `rolloutState` and `failedTasks` fields. Fix the root cause (bad image,
crash at startup, health check failing), then push a new image and re-register the
task def with the corrected SHA.

---

## 8. Redeploy after a code change (standard flow)

```bash
# 1. commit + push your changes
git add -A && git commit -m "fix: <description>"
git push origin feature/order-service-aws

# 2. rebuild + push
export SHA=$(git rev-parse --short HEAD)
docker build --platform linux/amd64 --build-arg GIT_SHA=$SHA -t $REPO_URI:$SHA ./order
docker push $REPO_URI:$SHA

# 3. re-register task def
sed "s|REPLACE_WITH_SHA|$SHA|" infra/order/task-def.json > /tmp/order-task-def.json
aws ecs register-task-definition --cli-input-json file:///tmp/order-task-def.json \
  --region $AWS_REGION --no-cli-pager

# 4. deploy
aws ecs update-service --cluster $CLUSTER --service devops-g3-order \
  --task-definition devops-g3-order --region $AWS_REGION --no-cli-pager
```

---

## 9. What is NOT set up yet (Phase 3+)

| Item | Phase |
|---|---|
| Service Connect namespace `group3.internal` | 3 |
| SG rules wiring order ↔ inventory ↔ payment | 3 |
| ALB + target group + listener | 3 |
| CodePipeline + CodeBuild (`buildspecs/order.yml`) | 5 |
