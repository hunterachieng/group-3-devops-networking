# Phase 2 — inventory service runbook

**Owner:** Joyce | **Service:** inventory | **Port:** 3002 | **Desired count:** 1
**Region:** us-west-1 | **Account:** 827478161993 | **Cluster:** devops-g3-cluster

Platform prerequisites (cluster, execution role, task role, log groups) are done —
see the Track 1 handover. This runbook covers only the inventory-owned resources:
ECR repo, image, security group, task definition, ECS service, checkpoint.

Every command passes `--region us-west-1` explicitly, per the platform decision.

---

## 0. Machine prerequisites

```bash
export AWS_PAGER=""                                # see scar 6; put this in ~/.zshrc
aws sts get-caller-identity --region us-west-1     # Account MUST read 827478161993
docker info >/dev/null && echo docker ok
session-manager-plugin --version                   # required for ECS Exec
git status --short                                 # must be empty before any build
```

Check the account **before** the first create command, not after something fails —
being added to the account does not configure the local CLI (scar 2). If your default
profile points elsewhere, use a named profile rather than overwriting it:
`aws configure --profile g3 && export AWS_PROFILE=g3`.

The Session Manager plugin is **not** part of the AWS CLI — `aws ecs execute-command`
fails without it. On macOS:

```bash
brew install --cask session-manager-plugin
```

This machine is Apple Silicon (`arm64`), so **every** build below must pass
`--platform linux/amd64`. Without it Fargate kills the task with an
exec-format error.

---

## 1. Shared variables

```bash
export REGION=us-west-1
export ACCOUNT=827478161993
export SERVICE=inventory
export PORT=3002
export CLUSTER=devops-g3-cluster
export REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/devops-g3-$SERVICE
export SHA=$(git rev-parse --short HEAD)
```

`$SHA` is the image tag. Never `latest` — the ECR repo is created with immutable
tags below, so a re-push of the same tag is rejected rather than silently
replacing what is deployed.

---

## 2. ECR repository

```bash
aws ecr create-repository \
  --repository-name devops-g3-$SERVICE \
  --image-tag-mutability IMMUTABLE \
  --region $REGION \
  --tags Key=Project,Value=devops-Ecommerce Key=Group,Value=group-3 \
         Key=Owner,Value=inventory-owner Key=Environment,Value=lab
```

MUTABLE is the ECR default, so omitting that flag is easy to do. Verify immediately,
while the repo is still empty, and flip it in place if needed — the repo does not have
to be deleted, but it must be immutable **before** the first push:

```bash
aws ecr describe-repositories --repository-names devops-g3-inventory \
  --region $REGION --query 'repositories[0].imageTagMutability'

aws ecr put-image-tag-mutability --repository-name devops-g3-inventory \
  --image-tag-mutability IMMUTABLE --region $REGION
```

> **Naming conflict to settle with the team before running this.** The Phase 2
> plan and `buildspecs/inventory.yml` both use `devops-g3-inventory`; section 8 of
> the Track 1 handover says `devops-g3/inventory`. This runbook uses the
> hyphenated form so the buildspec keeps working in Phase 5. If the team picks
> the slash form, the buildspec's `ECR_REPO_NAME` has to change too.

---

## 3. Build and push

```bash
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com

docker build --platform linux/amd64 --build-arg GIT_SHA=$SHA \
  -t devops-g3-$SERVICE:$SHA ./inventory

docker tag devops-g3-$SERVICE:$SHA $REPO:$SHA
docker push $REPO:$SHA
```

Verify the image landed and is amd64:

```bash
aws ecr describe-images --repository-name devops-g3-$SERVICE \
  --image-ids imageTag=$SHA --region $REGION \
  --query 'imageDetails[0].{tag:imageTags[0],arch:imageManifestMediaType,pushed:imagePushedAt}'
```

---

## 4. Security group

Phase 2 only needs the task to run and pass its **container-local** health check
(`curl localhost:3002/health` inside the container), so **no inbound rule is
required**. Default egress (all outbound) is what lets the task pull from ECR and
ship logs to CloudWatch. Cross-service ingress is Phase 3.

```bash
export VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --region $REGION --query 'Vpcs[0].VpcId' --output text)

export SG_ID=$(aws ec2 create-security-group \
  --group-name devops-g3-inventory-sg \
  --description "inventory service task SG (phase 2: egress only)" \
  --vpc-id $VPC_ID --region $REGION \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=devops-Ecommerce},{Key=Group,Value=group-3},{Key=Owner,Value=inventory-owner},{Key=Environment,Value=lab}]' \
  --query GroupId --output text)

echo $SG_ID
```

---

## 5. Register the task definition

`infra/inventory/taskdef.json` holds the definition. Its `image` field carries the
literal placeholder `IMAGE_SHA` so the committed file never pins a stale digest —
substitute at register time:

```bash
sed "s/IMAGE_SHA/$SHA/" infra/inventory/taskdef.json > /tmp/inventory-taskdef.json

aws ecs register-task-definition \
  --cli-input-json file:///tmp/inventory-taskdef.json \
  --region $REGION
```

What the file encodes, and why:

| Setting | Value | Reason |
|---|---|---|
| Launch type / network | FARGATE / awsvpc | required by the cluster |
| CPU / memory | 256 / 512 | Flask + gunicorn (2 workers) + curl; smallest Fargate combo. Revisit if OOM-killed |
| Port mapping name | `inventory-3002` | Service Connect resolves by this name in Phase 3 |
| Health check | `curl -f http://localhost:3002/health` | curl is baked into the image; the app has no shell-less distroless base |
| Log group | `/ecs/devops-g3/inventory` | per Track 1 handover (**not** `devops-g3-inventory-logs` from the plan doc — the handover names what actually exists) |
| PID 1 | gunicorn, exec-form `CMD` | receives SIGTERM directly, drains with `--graceful-timeout 30` |
| Task role | `devops-g3-task-role` | SSM messaging for ECS Exec; the app makes no other AWS calls |

---

## 6. Create the ECS service

```bash
export SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --region $REGION --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')

aws ecs create-service \
  --cluster $CLUSTER \
  --service-name devops-g3-inventory \
  --task-definition devops-g3-inventory \
  --desired-count 1 \
  --launch-type FARGATE \
  --enable-execute-command \
  --deployment-configuration \
     'deploymentCircuitBreaker={enable=true,rollback=true}' \
  --network-configuration \
     "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --region $REGION \
  --tags key=Project,value=devops-Ecommerce key=Group,value=group-3 \
         key=Owner,value=inventory-owner key=Environment,value=lab
```

Confirm the two subnets are in **different AZs** before running:

```bash
aws ec2 describe-subnets --subnet-ids ${SUBNETS//,/ } --region $REGION \
  --query 'Subnets[].{id:SubnetId,az:AvailabilityZone}'
```

`assignPublicIp=ENABLED` is a lab shortcut: these are public subnets with no NAT
gateway, and the task needs outbound reachability to ECR and CloudWatch. No ALB
and no Service Connect yet — both are Phase 3.

---

## 7. Checkpoint (Phase 2 exit criteria)

```bash
export TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-inventory \
  --region $REGION --query 'taskArns[0]' --output text)
```

**Task RUNNING + container HEALTHY**

```bash
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --region $REGION \
  --query 'tasks[0].{last:lastStatus,desired:desiredStatus,health:containers[0].healthStatus}'
```

**Application log line in CloudWatch** — the `service_starting` event is logged at
import time, so it appears once per gunicorn worker as soon as the task boots:

```bash
aws logs tail /ecs/devops-g3/inventory --region $REGION --since 10m
```

**Current SHA served + ECS Exec opens a shell**

```bash
aws ecs execute-command --cluster $CLUSTER --task $TASK \
  --container inventory --interactive --command "/bin/sh" --region $REGION
# inside the task:
curl -s localhost:3002/version
# expect: {"service":"inventory","status":"ok","version":"<the SHA from step 1>"}
```

---

## 8. Checklist

- [x] AWS CLI configured for account 827478161993
- [ ] Session Manager plugin installed — **still missing; blocks the ECS Exec checkpoint**
- [ ] ECR repo naming settled with the team (see step 2) — built as `devops-g3-inventory`
- [x] `devops-g3-inventory` ECR repo created — **verify immutability, it was created MUTABLE**
- [x] Image built `--platform linux/amd64`, tagged with the commit SHA, pushed
- [x] `devops-g3-inventory-sg` created
- [x] Task definition registered (named port `inventory-3002`, log group `/ecs/devops-g3/inventory`, health check, both roles)
- [x] ECS service created: desired 1, two AZs, public IP on, ECS Exec on — **confirm circuit breaker took**
- [ ] Checkpoint: RUNNING, HEALTHY, log line visible, SHA visible, `execute-command` shell succeeds
- [x] Scar log entries written for anything that failed on the way

---

## Live resource reference

Created 2026-07-21 by `arn:aws:iam::827478161993:user/Joyce`.

| Resource | Value |
|---|---|
| ECR image | `827478161993.dkr.ecr.us-west-1.amazonaws.com/devops-g3-inventory:d9e5430` |
| Image digest | `sha256:434fb9eee973a3e1916a463cb51c7e02e761f0111dafbf7d3e40212e42f5d69f` |
| Security group | `sg-050dcd78ace8718c3` |
| Subnets | `subnet-05505b0c5d0b340fd`, `subnet-0780a6a8bf1120301` |
| ECS service | `devops-g3-inventory` on `devops-g3-cluster` |

### Console links (region selector must read us-west-1)

- **ECS service** — RUNNING / HEALTHY, plus the events tab for failures:
  https://us-west-1.console.aws.amazon.com/ecs/v2/clusters/devops-g3-cluster/services/devops-g3-inventory/health?region=us-west-1
- **CloudWatch logs** — look for `service_starting`:
  https://us-west-1.console.aws.amazon.com/cloudwatch/home?region=us-west-1#logsV2:log-groups/log-group/$252Fecs$252Fdevops-g3$252Finventory
- **ECR repo** — tag, digest, and the immutability setting:
  https://us-west-1.console.aws.amazon.com/ecr/repositories/private/827478161993/devops-g3-inventory?region=us-west-1
- **Task definition**:
  https://us-west-1.console.aws.amazon.com/ecs/v2/task-definitions/devops-g3-inventory?region=us-west-1
- **Security group** — inbound must be empty:
  https://us-west-1.console.aws.amazon.com/ec2/home?region=us-west-1#SecurityGroup:groupId=sg-050dcd78ace8718c3

The console cannot cover two checkpoint items: ECS Exec has no console UI for Fargate,
and `/version` is only reachable from inside the task. Both are CLI-only. Screenshot
the ECS Tasks tab and the CloudWatch stream while they are green — task IDs change on
every redeploy and old links go dead.

---

## Scar log — inventory

Record symptom, first hypothesis, evidence, actual cause, repair, prevention.
Write the entry **before** repairing, not after.

### 1. No application log line in CloudWatch until the first request

- **Symptom:** the checkpoint requires a visible app log line, but the log group
  would stay empty after a healthy task boot until something hit an endpoint.
- **First hypothesis:** awslogs driver misconfigured, or the log group name wrong.
- **Evidence:** caught in review before deploying. The `service_starting` log call
  sat inside `if __name__ == "__main__"`, which gunicorn never executes — it
  imports `app:app` rather than running the module as a script. Only the Flask dev
  server (`python app.py`, local only) ever reached that line.
- **Actual cause:** startup logging placed in a code path that exists only for
  local development.
- **Repair:** moved the `service_starting` event to module scope in
  `inventory/app.py`, so it fires on import under gunicorn (once per worker).
- **Prevention:** anything that must be observable in production belongs at import
  time or in a gunicorn server hook, never in the `__main__` guard. order and
  payment carry the same pattern and need the same fix.

### 2. CLI authenticated to the wrong AWS account

- **Symptom:** `aws ecr describe-repositories --repository-names devops-g3-inventory`
  returned `RepositoryNotFoundException`.
- **First hypothesis:** the repo simply had not been created yet — which was true,
  but not the whole story.
- **Evidence:** the error names the registry it searched:
  `...does not exist in the registry with id '855139729154'`. The group account is
  `827478161993`. Only one profile (`default`) was configured locally.
- **Actual cause:** the default profile resolved to an unrelated account. Account
  membership does not configure the local CLI.
- **Repair:** switched to credentials for `827478161993`.
- **Prevention:** run `aws sts get-caller-identity` and confirm the account **before**
  the first create command in any session. Read the account id in error messages —
  it names which registry was actually searched. Use a named profile per account
  rather than overwriting `default`.

### 3. ECR repository created with mutable tags

- **Symptom:** `describe-repositories` reported `"mutability": "MUTABLE"`.
- **First hypothesis:** IMMUTABLE is the ECR default. It is not — MUTABLE is.
- **Evidence:** the repo was created without `--image-tag-mutability IMMUTABLE`.
- **Actual cause:** flag omitted at create time.
- **Repair:** `aws ecr put-image-tag-mutability --repository-name devops-g3-inventory
  --image-tag-mutability IMMUTABLE --region us-west-1`. Changeable in place; the repo
  does not need deleting, but it must be flipped **before** the first push.
- **Prevention:** verify mutability immediately after creating a repo, while it is
  still empty. A mutable tag lets a re-push silently replace the image under a
  running task, which breaks the SHA-to-image guarantee the checkpoint rests on.

### 4. Image tagged with a SHA that no longer matched HEAD

- **Symptom:** `docker tag devops-g3-inventory:$SHA ...` failed with
  `No such image: devops-g3-inventory:9cc2cfb`.
- **First hypothesis:** the build had failed.
- **Evidence:** the local image existed, tagged `ff0c762`. `git rev-parse` returned
  `9cc2cfb` — a commit made after the build.
- **Actual cause:** committing between build and push moves HEAD, so `$SHA` no
  longer names the image that was built. An earlier variant of the same mistake:
  `$SHA` was empty in a fresh shell, producing
  `Invalid length for parameter imageIds[0].imageTag, value: 0`.
- **Repair:** commit all outstanding work first, then build and push once at the
  final SHA.
- **Prevention:** `echo $SHA` before using it, and treat build-then-push as a single
  uninterrupted step. Never commit in between.

### 5. Pushed image does not match the commit it is tagged with — OPEN

- **Symptom:** none yet. The image will behave correctly; the tag is what is wrong.
- **Evidence:** `docker build` reads the **working tree**, not git. The Phase 2 work
  (`inventory/app.py` startup-log fix, `infra/inventory/taskdef.json`, this document)
  was staged but uncommitted when the image was built, so the image tagged `d9e5430`
  contains the fix while commit `d9e5430` — a merge of PR #31 — does not.
- **Actual cause:** building from a dirty working tree. The tag names a commit that
  never contained the code inside the image.
- **Repair (not yet applied):** commit the branch, rebuild at the new SHA, push, and
  register a new task definition revision against it. The orphaned `d9e5430` image
  can stay in ECR as long as nothing references it.
- **Prevention:** build only from a clean working tree. `git status --short` must be
  empty before `docker build`, otherwise `/version` cannot prove what is running.
  This is the reason the checkpoint asks for the SHA at all.

### 6. AWS CLI pager suspended the shell mid-command

- **Symptom:** `zsh: suspended  aws ecs create-service ...`, then the next pasted
  command failed with `zsh: bad pattern: [200~`.
- **First hypothesis:** the create-service call had failed or hung.
- **Evidence:** the service JSON had already printed in full, and the service existed.
  The AWS CLI pipes long output into a pager by default; the pager was backgrounded,
  leaving the terminal in bracketed-paste mode so the next paste arrived as the
  literal escape text `[200~`.
- **Actual cause:** terminal state, not AWS. Nothing was wrong with the resource.
- **Repair:** `kill %1`, then `printf '\e[?2004l'` to clear bracketed paste (`reset`
  if pastes still misbehave).
- **Prevention:** `export AWS_PAGER=""` in `~/.zshrc`. A suspended pager mid-sequence
  reads like a failed command and invites re-running creates that already succeeded.
