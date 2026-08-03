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
# In terraform.tfvars, set tags back to previous SHAs
terraform plan
terraform apply
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
