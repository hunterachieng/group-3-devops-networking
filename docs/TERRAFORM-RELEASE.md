# Terraform Release Model — Group 3 Lab

**Region:** `us-west-1` | **ECR prefix:** `devops-g3-iac-*`  
**IaC root:** `infra/environments/lab/`

Pipeline builds and pushes images. Terraform selects which Git SHA is deployed. The console `devops-g3-*` ECR repos are **not** used for this assignment.

---

## 1. Responsibility split

| Step | Who | Action |
|------|-----|--------|
| Code change + tests | Service owner (Hunter / Joyce / Wairimu) | Merge to main via PR |
| Build image | CI / CodeBuild (`buildspecs/`) | `docker build --platform linux/amd64` |
| Tag image | CI | Git commit SHA (e.g. `09823d5`) — **never `latest`** |
| Push to ECR | CI | `devops-g3-iac-order`, `-inventory`, `-payment` |
| Select SHA for deploy | Release owner (Minage) | Update `terraform.tfvars` |
| Deploy | Release owner + reviewer | `terraform plan` → review → `apply` |
| Prove | Any owner | ALB `/health` or `/version` shows new SHA |

---

## 2. Release flow

```text
Application change (merged PR)
  ↓
Tests pass in CI
  ↓
Build SHA-tagged image (--platform linux/amd64)
  ↓
Push to devops-g3-iac-<service> ECR repo
  ↓
Update image tag in infra/environments/lab/terraform.tfvars
  ↓
terraform plan   (review: task definition revision change expected)
  ↓
terraform apply  (ECS rolling deployment)
  ↓
Runtime proof: GET /health or /version via ALB shows deployed SHA
  ↓
terraform plan   (must show no unintended changes)
```

---

## 3. Local variables file

```bash
cd infra/environments/lab
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` (gitignored):

```hcl
order_image_tag     = "abc1234"   # real Git SHA from ECR
inventory_image_tag = "def5678"
payment_image_tag   = "9012abc"
```

Commit **only** `terraform.tfvars.example` — never commit `terraform.tfvars`.

---

## 3a. Automated deploy script (preferred)

`scripts/deploy-iac.sh` replaces the manual tfvars editing step. It reads the latest
Git SHA for each service from SSM Parameter Store (published automatically by each
service's CodeBuild `post_build` step) and runs the full `plan → apply → smoke test →
clean plan` cycle.

### SSM parameters (written by CI, read by the script)

| Service | SSM parameter |
|---------|--------------|
| order | `/devops-g3-iac/order/image-tag` |
| inventory | `/devops-g3-iac/inventory/image-tag` |
| payment | `/devops-g3-iac/payment/image-tag` |

### Credentials setup (required before running the script)

Terraform uses the standard AWS SDK credential chain. The `login_session` plugin in
`~/.aws/config` is **not** picked up by Terraform — export real credentials first:

```bash
# Option A — if your CLI version supports it:
eval $(aws configure export-credentials --format env)
echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"   # must be non-empty

# Option B — paste the three export lines from your lab portal:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...

# Verify before running anything:
aws sts get-caller-identity --region us-west-1   # must return 827478161993
```

### Usage

```bash
# deploy all services (reads all SHAs from SSM automatically)
./scripts/deploy-iac.sh

# override one service's SHA (e.g. after a manual build)
./scripts/deploy-iac.sh order=abc1234

# override all three
./scripts/deploy-iac.sh order=abc1234 inventory=def5678 payment=ghi9012
```

Services whose SSM parameter is not yet set (pipeline hasn't run) keep `REPLACE_ME`
and Terraform leaves those task definitions unchanged.

The script exits non-zero and aborts before apply if the resolved SHA is not found in
the corresponding ECR repo, preventing a deploy of a non-existent image.

### Full release flow with the script

```text
Service owner merges PR to main
  ↓
CodePipeline auto-triggers (WebhookV2)
  ↓
CodeBuild builds + pushes SHA to devops-g3-iac-<service> ECR
CodeBuild writes SHA to SSM /devops-g3-iac/<service>/image-tag
  ↓
Release owner (or any team member) runs:
  eval $(aws configure export-credentials --format env)
  ./scripts/deploy-iac.sh
  ↓
Script: reads all SHAs from SSM → verifies ECR → plan → prompt → apply → smoke test → clean plan
  ↓
ALB /health and /version show the new SHA
```

---

## 4. Validation rules (in code)

`infra/environments/lab/variables.tf` rejects:

- `latest` (any casing) on any image tag variable
- Tags that are not valid Git SHAs (unless still `REPLACE_ME` before first deploy)

`terraform plan` fails before apply if someone sets `latest`.

**Prove rejection:**

```bash
cd infra/environments/lab
terraform plan -var='order_image_tag=latest'
# Expect: Error: order_image_tag must not be "latest"
```

---

## 5. Rollback

Rollback is redeploying the **previous known-good SHA** — no console changes.

```bash
# pass the previous good SHAs explicitly (overrides SSM)
./scripts/deploy-iac.sh order=<previous-good-sha>

# or all three if needed
./scripts/deploy-iac.sh order=<sha> inventory=<sha> payment=<sha>
```

Evidence: ALB response shows the old SHA again; ECS service events show task definition rollback revision.

---

## 6. Runtime evidence (per cycle / demo)

After each release, capture:

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names devops-g3-iac-alb \
  --query 'LoadBalancers[0].DNSName' --output text --region us-west-1)

curl -s "http://${ALB_DNS}/health" | python3 -m json.tool
# Expect "version" or equivalent field matching terraform.tfvars SHA
```

Also keep:

- `terraform plan` output (shows image → task definition change)
- ECS task definition revision number after apply
- Clean follow-up `terraform plan` (zero changes)

---

## 7. Architecture decision card — Immutable Git SHA

**Decision:** Deploy only immutable Git SHA image tags via Terraform variables. Reject `latest`.

| Question | Answer |
|----------|--------|
| What risk are we reducing? | Untraceable deploys, accidental overwrites when `latest` moves, no link between running code and git commit |
| What trade-off are we accepting? | Every release requires updating IaC and running plan/apply; cannot “just push latest” from console |
| Well-Architected pillar | Operational Excellence |
| What evidence proves it works? | Variable validation fails on `latest`; ALB `/health` shows SHA matching `terraform.tfvars`; ECR repos use `IMMUTABLE` tag mutability |

**Prevention encoded in repo:**

- `variables.tf` validation on `order_image_tag`, `inventory_image_tag`, `payment_image_tag`
- `terraform.tfvars.example` documents SHA-only policy
- Architecture tests (Step 9) will assert `latest` is rejected

---

## 8. Before first real release

Wait until:

1. Lwam’s `ecs-platform` module creates `devops-g3-iac-*` ECR repos
2. CI or manual push puts SHA-tagged images in those repos
3. Lab `main.tf` wires `ecs-service` modules

Then replace `REPLACE_ME` in `terraform.tfvars` with real SHAs and apply.
