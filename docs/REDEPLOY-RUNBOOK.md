# Redeploy Runbook — full account loss / migration

**Audience:** whoever is on call when this happens — including a junior engineer
doing it for the first time, with no prior context beyond this document.

**Scope:** what to do when the AWS account this project lives in is closed,
deleted, or replaced, and every AWS resource needs to be rebuilt from scratch in
a new account.

**Last executed:** 2026-08-26/27, migrating from account `827478161993`
(closed) to `240462142849`, region `us-west-1` (unchanged). Every command below
was run for real during that migration; the Evidence appendix (§9) has the real
output.

---

## 1. When to use this runbook

Use this if **any** of these are true:

- `aws sts get-caller-identity` returns an account ID that doesn't match what's
  hardcoded in `infra/environments/lab/backend.tf` / `infra/bootstrap/main.tf`.
- The old AWS account was closed, suspended, or replaced by a new one (common in
  training-lab accounts that expire/rotate).
- `terraform plan` in `infra/environments/lab` fails to reach the S3 backend at
  all (bucket doesn't exist / access denied to a bucket in another account).

Do **not** use this runbook for a routine image redeploy (new code, same
account) — that's `docs/TERRAFORM-RELEASE.md` and `scripts/deploy-iac.sh`. This
runbook is for rebuilding everything, not shipping a new SHA.

---

## 2. Before you start

**Access you need:**

- AWS console/CLI access to the **new** account, with permissions broad enough
  to create IAM roles, VPCs, ECS/ALB/ECR resources, and S3 buckets. (In a
  training lab this is usually your assigned SSO role — ask whoever issued the
  new account if you don't have it yet.)
- Write access to this GitHub repo (to open PRs — `main` is branch-protected,
  direct pushes are rejected).
- Local tools: `aws` CLI v2, `terraform` (>= 1.11), `docker` with the daemon
  running, `git`.

**Know these two identifiers before you start:**

| | |
|---|---|
| Old account ID | find it in `infra/environments/lab/backend.tf` (the `bucket` value has it baked in) |
| New account ID | `aws sts get-caller-identity --query Account --output text` |
| Region | fixed — `us-west-1` for this project, enforced by a `variables.tf` validation rule. Do not change it. |

**5-minute mental model before you touch anything:** this project has two
layers that depend on the AWS account, and they break differently:

1. **Terraform-managed infra** (`infra/environments/lab` + modules) — VPC, ALB,
   ECS cluster, ECR repos, IAM roles, the 3 services. Fully defined as code.
   Its only account-specific detail is the S3 state bucket name.
2. **Console/CLI-managed CI/CD** (CodeBuild, CodePipeline, their IAM roles, the
   GitHub connection) — these are **not** Terraform-managed for the per-service
   pipelines (only the GitHub Actions deploy role is, as of this migration —
   see §7). They have to be recreated by hand every time the account changes.

---

## 3. Step-by-step procedure

### 3.1 — Re-authenticate and confirm the new account

```bash
aws login                                    # or however your org issues creds
aws sts get-caller-identity --region us-west-1
```

**Expect:** a JSON block with `"Account"` matching the new account ID. Write
that number down — you'll need it for every step below.

Terraform does **not** use the same session your `aws login` sets up. Export
real credentials into the shell before running any `terraform` command:

```bash
eval $(aws configure export-credentials --format env)
echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"   # must print something, not empty
```

> ⚠️ Re-run this `eval` line in **every new terminal/shell session** — exported
> credentials don't persist across shells, and if your SSO session expires
> mid-task, AWS calls will fail with a credentials error until you `aws login`
> again and re-export.

### 3.2 — Update every hardcoded old-account reference

```bash
cd group-3-devops-networking
grep -rln "OLD_ACCOUNT_ID" . --include="*.tf" --include="*.json"
```

Replace `OLD_ACCOUNT_ID` with the real old ID. As of this writing that touches:

- `infra/bootstrap/main.tf` (state bucket name)
- `infra/environments/lab/backend.tf` (state bucket name)
- `infra/order/task-def.json`, `infra/inventory/taskdef.json`,
  `infra/payment/task-definition-payment.json` (role ARNs, image URI)
- `infra/inventory/codebuild-project.json`, `infra/payment/codebuild-project-payment.json`
  (service role ARN)
- `infra/inventory/pipeline-inventory.json`, `infra/payment/pipeline-payment.json`
  (role ARN, artifact bucket name, CodeConnections ARN)

```bash
for f in $(grep -rl "OLD_ACCOUNT_ID" . --include="*.tf" --include="*.json"); do
  sed -i '' "s/OLD_ACCOUNT_ID/NEW_ACCOUNT_ID/g" "$f"
done
```

**One thing `sed` cannot fix:** the CodeConnections `ConnectionArn` contains a
connection UUID that belongs to the old account and cannot be reused — its
account-ID portion will get swapped by the command above, but the object it
points to doesn't exist in the new account. Replace the whole ARN with a
placeholder for now (`REPLACE_WITH_NEW_CODECONNECTIONS_ARN`) — §3.6 creates the
real one.

**Verify:**

```bash
grep -rln "OLD_ACCOUNT_ID" . --include="*.tf" --include="*.json"   # must print nothing
```

### 3.3 — Rebuild the Terraform state backend

The old state bucket lived in the closed account — it's gone, and there is
nothing to migrate or import. This is a fresh bucket, not a restore.

```bash
cd infra/bootstrap
terraform init -input=false
terraform plan -out=tfplan.bootstrap     # expect: 4 to add (bucket + versioning + SSE + public-access-block), 0 to destroy
terraform apply tfplan.bootstrap
```

**Verify:** the apply output's `state_bucket_name` matches what you put in
`backend.tf` in §3.2.

### 3.4 — Reset a stuck state lock (only if you hit one)

You will not normally need this on a fresh bucket — there's nothing to lock
yet. You **will** need it if a previous `terraform plan`/`apply` was
interrupted (crashed CI run, killed process, network drop) and left a lock
behind. Symptom:

```
Error: Error acquiring the state lock
Lock Info:
  ID:        <uuid>
  ...
```

**Do not skip straight to `force-unlock`.** First confirm nobody else is
actually running Terraform against this state right now — ask in your team
channel, check if a CI run is in progress. Once you're sure the lock is stale:

```bash
cd infra/environments/lab   # or infra/bootstrap, wherever the lock is
terraform force-unlock -force <LOCK_ID>
```

Then confirm the state is usable again:

```bash
terraform plan -detailed-exitcode
# exit 0 = clean, no changes
# exit 2 = changes pending (fine, just means real drift)
# exit 1 = still broken, don't proceed — escalate
```

> This actually happened during this migration (see §9.5) — a CI run's
> deploy job failed mid-apply, couldn't release its lock because of a
> permissions gap (since fixed), and left `terraform.tfstate.tflock` stuck in
> S3 until we ran the command above.

### 3.5 — Deploy the core infrastructure from scratch

```bash
cd infra/environments/lab
terraform init -reconfigure -input=false
cp terraform.tfvars.example terraform.tfvars   # leave all three image tags as REPLACE_ME
terraform plan -out=tfplan.lab                  # expect ~57 resources to add, 0 to destroy
terraform apply tfplan.lab
```

**Expect:** this creates the VPC, ALB, ECS cluster + IAM roles + ECR repos + log
groups, and all 3 ECS services. The services will show **0 running tasks**
right after this — that's correct and expected, because `REPLACE_ME` isn't a
real image tag yet. Don't panic; §3.7 fixes that.

**Verify:**

```bash
terraform output ecr_repository_urls
terraform output alb_dns_name
```

Both should print real values, not errors.

### 3.6 — Rebuild the CI/CD layer (IAM roles, artifact bucket, CodeConnections, CodeBuild, CodePipeline)

None of this is Terraform-managed (except the GitHub Actions role in §3.8), so
it's recreated with the AWS CLI directly, once, by hand.

**a) IAM roles** — four of them, none pre-existing in a new account:

| Role | Trusted by | Purpose |
|---|---|---|
| `devops-g3-execution-role` | `ecs-tasks.amazonaws.com` | ECS task execution (image pull, log push) — attach managed policy `AmazonECSTaskExecutionRolePolicy` |
| `devops-g3-task-role` | `ecs-tasks.amazonaws.com` | ECS task runtime — needs only `ssmmessages:Create/OpenControlChannel` and `ssmmessages:Create/OpenDataChannel` for ECS Exec |
| `devops-g3-codebuild-role` | `codebuild.amazonaws.com` | Build + push images — scope ECR actions to `devops-g3-iac-*` repos only, plus CloudWatch Logs, the artifact bucket, and `ssm:PutParameter` on `/devops-g3-iac/*/image-tag` |
| `devops-g3-codepipeline-role` | `codepipeline.amazonaws.com` | Orchestrate the pipeline — artifact bucket R/W, `codebuild:StartBuild`/`BatchGetBuilds`, `codeconnections:UseConnection` |

Create each with `aws iam create-role` (trust policy) then
`aws iam put-role-policy` (permissions) or `attach-role-policy` for the managed
one. **Least privilege matters here** — don't grant `ecr:*` on `Resource: "*"`
when it can be scoped to `devops-g3-iac-*`.

**b) Artifact bucket:**

```bash
aws s3api create-bucket --bucket devops-g3-codepipeline-artifacts-NEW_ACCOUNT_ID-us-west-1 \
  --region us-west-1 --create-bucket-configuration LocationConstraint=us-west-1
aws s3api put-public-access-block --bucket devops-g3-codepipeline-artifacts-NEW_ACCOUNT_ID-us-west-1 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**c) GitHub connection:**

```bash
aws codeconnections create-connection --provider-type GitHub \
  --connection-name devops-g3-github --region us-west-1
```

This comes back `PENDING`. **It cannot be finished by CLI or by an
engineer working alone at a keyboard with no browser** — someone with GitHub
repo-owner access must go to **AWS Console → Developer Tools → Settings →
Connections → devops-g3-github → Update pending connection**, complete the
GitHub OAuth prompt, and — this is the part that's easy to miss — confirm the
**"AWS Connector for GitHub" app is installed** on the repo (not just
OAuth-authorized; those are two different things, see §7 for why this matters
for webhooks specifically). Don't proceed past this step until
`aws codeconnections get-connection --connection-arn <arn> --query 'Connection.ConnectionStatus'`
returns `AVAILABLE`.

Paste the resulting ARN into every pipeline JSON where you left the
`REPLACE_WITH_NEW_CODECONNECTIONS_ARN` placeholder in §3.2.

**d) CodeBuild projects + CodePipelines** — one of each per service
(order/inventory/payment):

```bash
aws codebuild create-project --cli-input-json file://infra/order/codebuild-project-order.json --region us-west-1
aws codebuild create-project --cli-input-json file://infra/inventory/codebuild-project.json --region us-west-1
aws codebuild create-project --cli-input-json file://infra/payment/codebuild-project-payment.json --region us-west-1

aws codepipeline create-pipeline --cli-input-json file://infra/order/pipeline-order.json --region us-west-1
aws codepipeline create-pipeline --cli-input-json file://infra/inventory/pipeline-inventory.json --region us-west-1
aws codepipeline create-pipeline --cli-input-json file://infra/payment/pipeline-payment.json --region us-west-1
```

**Two things to check in these JSON files before you run the above** — both
are real bugs found and fixed during this migration (full detail in §8):

- `"DetectChanges"` **must be `"true"`** on every pipeline's Source action. If
  it's `"false"` or missing, the pipeline will never auto-trigger on a GitHub
  push — it silently sits there and you'll only ever see manual/`CreatePipeline`
  executions, never a `WebhookV2` one.
- The pipelines should **not** have an ECS "Deploy" stage. Real deploys happen
  through `terraform apply` (manually or via GitHub Actions, §3.8) — a
  leftover Deploy stage will point at stale cluster/service names from before
  the Terraform rewrite and just fail.

### 3.7 — Unblock the services if CodeBuild can't build yet

New AWS accounts commonly start with a CodeBuild concurrency quota of **0** —
you can create projects and pipelines fine, but every actual build fails
instantly with `AccountLimitExceededException`. Check:

```bash
aws service-quotas get-service-quota --service-code codebuild --quota-code L-9D07B6EF --region us-west-1
```

If `Value` is `0`, file an increase (this is a normal, low-risk, free request —
not a support ticket that costs anything):

```bash
aws service-quotas request-service-quota-increase \
  --service-code codebuild --quota-code L-9D07B6EF --desired-value 2 --region us-west-1
```

This can take anywhere from minutes to over a day to clear, and there's no way
to force it — **don't block the rest of the redeploy waiting on it.** Unblock
the actual services immediately instead:

```bash
eval $(aws configure export-credentials --format env)
aws ecr get-login-password --region us-west-1 | docker login --username AWS \
  --password-stdin NEW_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com

SHA=$(git rev-parse --short=7 HEAD)
for svc in order inventory payment; do
  REPO=NEW_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/devops-g3-iac-$svc
  docker build --platform linux/amd64 --build-arg GIT_SHA=$SHA -t $REPO:$SHA ./$svc
  docker push $REPO:$SHA
  aws ssm put-parameter --region us-west-1 --name "/devops-g3-iac/$svc/image-tag" \
    --value "$SHA" --type String --overwrite
done
```

> If `docker build` fails with something like `failed to connect to the docker
> API` on macOS, Docker Desktop is installed but its daemon isn't running —
> open Docker Desktop and wait for it to finish starting, then retry.

Then deploy those images:

```bash
cd infra/environments/lab
terraform plan \
  -var="order_image_tag=$SHA" -var="inventory_image_tag=$SHA" -var="payment_image_tag=$SHA" \
  -out=tfplan.lab
terraform apply tfplan.lab
```

Update `terraform.tfvars` with the real SHA too, so a future bare
`terraform apply` doesn't revert to `REPLACE_ME`.

> `scripts/deploy-iac.sh` automates the block above (reads SHAs from SSM,
> verifies them in ECR, plans, prompts, applies, smoke-tests). **It requires
> bash 4+ for associative arrays** — macOS ships bash 3.2 by default and the
> script will fail immediately with `declare: -A: invalid option`. Either
> `brew install bash` first, or just run the equivalent commands above by hand.

### 3.8 — Wire GitHub Actions to deploy to the new account

This lets `terraform apply` run automatically on every merge to `main`,
authenticated via GitHub's OIDC token — no long-lived AWS credentials stored in
the repo.

**a) Confirm (or create) the GitHub OIDC provider:**

```bash
aws iam list-open-id-connect-providers --region us-west-1
```

If `token.actions.githubusercontent.com` isn't listed, create it — but check
first whether your new account already has one provisioned account-wide (it
often does in a shared/training account); don't create a duplicate.

**b) Codify the deploy role in Terraform**, in `infra/bootstrap/main.tf` — a
role trusted only by this repo's `main` branch (see the file for the exact
resource block: `data.aws_iam_openid_connect_provider`, the assume-role policy
document scoped with `token.actions.githubusercontent.com:sub` =
`repo:<owner>/<repo>:ref:refs/heads/main`, and the permissions policy scoped to
what `terraform apply` actually needs — VPC/ALB/ECS/ECR, the state bucket, SSM
image-tag parameters, and IAM actions scoped to `devops-g3-iac-*` roles only).

```bash
cd infra/bootstrap
terraform apply
```

**c) The workflow itself** (`.github/workflows/terraform.yml`) has a `deploy`
job that only runs `if: github.ref == 'refs/heads/main' && github.event_name
== 'push'`. It assumes the role, reads each service's current image tag from
SSM (so an infra-only merge can never accidentally roll a running service back
to `REPLACE_ME`), then plans and applies.

**Verify** by merging any change into `main` and checking the Actions run — see
§8 for the two real permission gaps this surfaced the first time, already
fixed, so you shouldn't hit them again.

### 3.9 — Confirm all three services are up

```bash
ALB_URL=$(cd infra/environments/lab && terraform output -raw alb_url)
curl -s "$ALB_URL/health" | python3 -m json.tool
curl -s "$ALB_URL/version" | python3 -m json.tool
curl -s -X POST "$ALB_URL/checkout" -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}' | python3 -m json.tool

aws ecs describe-services --cluster devops-g3-iac-cluster \
  --services devops-g3-iac-order devops-g3-iac-inventory devops-g3-iac-payment \
  --region us-west-1 \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount,status:status}' \
  --output table
```

**Done when:** `/health` returns `"status": "ok"`, `/checkout` returns
`"outcome": "success"` with a populated `pipeline` object showing the order →
inventory → payment → confirm hop, and every service shows
`running == desired` and `status: ACTIVE`.

---

## 4. Ship every change through a PR

`main` is branch-protected — a direct `git push origin main` will be rejected
with `GH006: Protected branch update failed`. Every change from this runbook
goes out as a feature branch + PR:

```bash
git checkout -b fix/whatever-you-changed
git add <files>
git commit -m "..."
git push -u origin fix/whatever-you-changed
```

Then open the PR from the URL git prints, or via `gh pr create` if the `gh`
CLI is installed (it wasn't, on the machine this was last run from).

---

## 5. Verification checklist

Copy this into the PR description or an incident ticket when you're done:

- [ ] `aws sts get-caller-identity` confirms the new account and `us-west-1`
- [ ] No leftover references to the old account ID (`grep` from §3.2 is clean)
- [ ] `terraform plan` is clean (`No changes`) in both `infra/bootstrap` and
      `infra/environments/lab`
- [ ] All 3 ECS services show `running == desired` and `ACTIVE`
- [ ] `/health`, `/version`, and a full `/checkout` smoke test all succeed
- [ ] GitHub Actions `deploy` job succeeds on a real merge to `main`
- [ ] No stuck Terraform state lock (`terraform plan` doesn't hang/error on
      lock acquisition)

---

## 6. Rollback

Rolling back a *code* deploy (bad SHA) is not this runbook — see
`docs/TERRAFORM-RELEASE.md` §5 (`scripts/deploy-iac.sh order=<previous-sha>`).

Rolling back *this* runbook (undoing an in-progress account migration) mostly
isn't meaningful — there's no "old account" to go back to by definition. If a
specific step here made things worse:

- A bad `terraform apply` — fix the `.tf` and re-apply; don't hand-edit
  resources in the console, it will drift from state.
- A bad IAM policy change — same: fix it in Terraform (or in the JSON for the
  hand-created CI/CD roles) and re-apply/re-run the CLI command, don't patch it
  in the console only.
- A stuck state lock from a bad apply — §3.4.

---

## 7. Design notes worth knowing before you touch this

- **Two separate deploy paths exist and don't talk to each other directly.**
  CodePipeline/CodeBuild only ever build an image and record its tag in SSM
  Parameter Store (`/devops-g3-iac/<service>/image-tag`). GitHub Actions only
  ever reads that tag back and runs `terraform apply`. They're triggered
  independently by the same GitHub push. If a deploy isn't picking up a new
  image, check whether the SSM parameter actually got written before assuming
  Terraform is broken.
- **`DetectChanges` and GitHub App installation are two different things.**
  A CodeConnections connection showing `AVAILABLE` proves OAuth succeeded —
  it does **not** prove the "AWS Connector for GitHub" app is installed on the
  repo, which is what actually delivers push *events* (webhooks), as opposed to
  just allowing pipeline *reads*. Both must be true for auto-trigger to work.
- **Order's pipeline intentionally has no `filePaths` trigger filter** while
  inventory/payment's do. This was a deliberate fix, not an oversight — a
  GitHub "create a merge commit" push can deliver an empty file list for the
  merge commit itself, which silently drops a `filePaths`-filtered trigger.
  Order only has one service in its pipeline, so there was nothing to filter
  for in the first place.

---

## 8. Known issues found (and fixed) during this migration

| Symptom | Root cause | Fix |
|---|---|---|
| Pipeline never auto-triggered on a `main` merge | `DetectChanges` was `false`/absent on the Source action | Set `"DetectChanges": "true"` on all three pipeline JSONs |
| CodePipeline had a Deploy stage that never matched reality | Leftover from before the Terraform rewrite, pointed at the old `devops-g3-cluster` naming | Dropped the Deploy stage entirely — deploys go through Terraform/GitHub Actions |
| Every CodeBuild run failed instantly, `AccountLimitExceededException` | New account defaults CodeBuild concurrency to `0` | Filed a Service Quotas increase; used manual `docker build`/`push` in the meantime (§3.7) |
| `scripts/deploy-iac.sh` failed: `declare: -A: invalid option` | macOS ships bash 3.2 (no associative arrays); the script needs bash 4+ | Run the equivalent `terraform plan`/`apply` commands by hand, or `brew install bash` |
| `git push origin main` rejected: `GH006` | `main` requires PRs, no direct pushes | Feature branch + PR for every change (§4) |
| First real GitHub Actions deploy run failed at `terraform plan`: `AccessDeniedException` on `logs:DescribeLogGroups` | `logs:DescribeLogGroups` is a list-type call AWS only supports at `Resource: "*"` — it was scoped to a specific log-group ARN pattern instead, which that particular action can never match | Split it into its own unscoped statement (see `infra/bootstrap/main.tf`, statement `LogGroupsList`) |
| Same run also failed to release its state lock: `AccessDenied` on `s3:DeleteObject` for `terraform.tfstate.tflock` | `s3:DeleteObject` was missing from the deploy role's state-bucket policy | Added it; then cleared the resulting stuck lock with `terraform force-unlock` (§3.4) |

---

## 9. Evidence (from the actual 2026-08-26/27 migration)

### 9.1 — New account confirmed

```json
{
    "UserId": "AROATP7FJDWAW3OLI4A6P:wairimuznganga@gmail.com",
    "Account": "240462142849",
    "Arn": "arn:aws:sts::240462142849:assumed-role/AWSReservedSSO_DevOpsCohort-group3-us-west-1_725a079de6298063/wairimuznganga@gmail.com"
}
```

### 9.2 — Core infra applied clean (`infra/environments/lab`)

```
Apply complete! Resources: 57 added, 0 changed, 0 destroyed.

Outputs:
alb_dns_name = "devops-g3-iac-alb-1541676775.us-west-1.elb.amazonaws.com"
alb_url = "http://devops-g3-iac-alb-1541676775.us-west-1.elb.amazonaws.com"
cluster_name = "devops-g3-iac-cluster"
service_names = {
  "inventory" = "devops-g3-iac-inventory"
  "order" = "devops-g3-iac-order"
  "payment" = "devops-g3-iac-payment"
}
```

### 9.3 — All three services confirmed running

```
--------------------------------------------------------------
|                      DescribeServices                      |
+---------+---------------------------+----------+-----------+
| desired |           name            | running  |  status   |
+---------+---------------------------+----------+-----------+
|  2      |  devops-g3-iac-order      |  2       |  ACTIVE   |
|  1      |  devops-g3-iac-inventory  |  1       |  ACTIVE   |
|  1      |  devops-g3-iac-payment    |  1       |  ACTIVE   |
+---------+---------------------------+----------+-----------+
```

### 9.4 — End-to-end smoke test

```json
// GET /health
{ "service": "order-service", "status": "ok", "version": "598664c" }

// POST /checkout {"items":["BOOK-42"],"amount":3500}
{
    "order_id": "ORD-51952E0B",
    "outcome": "success",
    "pipeline": {
        "downstream": {
            "amount": 3500,
            "confirm": "sent",
            "order_id": "ORD-51952E0B",
            "outcome": "success",
            "service": "payment-service"
        },
        "order_id": "ORD-51952E0B",
        "outcome": "success",
        "service": "inventory-service"
    },
    "service": "order-service"
}
```

### 9.5 — The stuck state lock, and its resolution

The first automated GitHub Actions deploy run failed and could not release its
lock:

```
Error: Error releasing the state lock

Error message: failed to delete the lock file: operation error S3:
DeleteObject, https response error StatusCode: 403, ...
api error AccessDenied: User:
arn:aws:sts::240462142849:assumed-role/devops-g3-gha-deploy-role/GitHubActions
is not authorized to perform: s3:DeleteObject on resource:
"arn:aws:s3:::devops-g3-tfstate-240462142849-uswest1/workload/lab/terraform.tfstate.tflock"
because no identity-based policy allows the s3:DeleteObject action
Lock Info:
  ID:        52f352eb-eb31-b158-12ff-6a9615e394e4
  Path:      devops-g3-tfstate-240462142849-uswest1/workload/lab/terraform.tfstate
  Operation: OperationTypePlan
  Who:       runner@runnervmgx7h7
  Created:   2026-08-26 20:32:08 UTC
```

Resolution:

```
$ terraform force-unlock -force 52f352eb-eb31-b158-12ff-6a9615e394e4
Terraform state has been successfully unlocked!

$ terraform plan -detailed-exitcode
No changes. Your infrastructure matches the configuration.
exit: 0
```

The underlying permission gap was fixed in
`infra/bootstrap/main.tf` (PR `fix/gha-deploy-role-permissions`), and
`terraform apply` on `infra/bootstrap` confirmed clean afterward:

```
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

### 9.6 — Pull requests from this migration

| PR | What it shipped |
|---|---|
| [#71](https://github.com/hunterachieng/group-3-devops-networking/pull/71) | Account ID migration across Terraform + pipeline JSON, dropped stale Deploy stages, fixed `DetectChanges` |
| [#72](https://github.com/hunterachieng/group-3-devops-networking/pull/72) | GitHub Actions OIDC deploy role + `deploy` job in the Terraform workflow |
| `fix/gha-deploy-role-permissions` | Fixed the `logs:DescribeLogGroups` and `s3:DeleteObject` permission gaps found by PR #72's first real run |

### 9.7 — CodeBuild quota request filed

```json
{
    "QuotaCode": "L-9D07B6EF",
    "QuotaName": "Concurrently running builds for Linux/Small environment",
    "DesiredValue": 2.0,
    "Status": "CASE_OPENED",
    "CaseId": "178777249600782"
}
```

---

## 10. Related docs

- `docs/TERRAFORM-RELEASE.md` — the routine (same-account) release/rollback flow
- `docs/architecture.md` — full service architecture and request flow
- `docs/NETWORK-SECURITY.md` — the network security model this infra enforces
- `docs/TERRAFORM-GATE1-DESIGN.md` — original design rationale for the Terraform layout
