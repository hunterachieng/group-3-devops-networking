# Terraform Gate 1 Design

This document defines the Terraform plan for the new Group 3 AWS ECS Fargate environment.

This is a greenfield Infrastructure as Code build. Terraform will create a new environment from an empty workload state. It will not import or replace the existing console-created AWS setup.

The existing console environment stays running:

```text
devops-g3-*
```

The new Terraform-managed environment will use:

```text
devops-g3-iac-*
```

This allows both environments to exist at the same time for the demo.

## 1. Goal

We need to rebuild the AWS ECS Fargate architecture in Terraform so the infrastructure is:

- reproducible from the repository;
- reviewed before creation;
- safe to destroy and rebuild;
- secure by default;
- observable through CloudWatch;
- releasable using immutable Git SHA image tags;
- testable with evidence instead of assumptions.

The expected workflow is:

```text
Predict → Plan → Review → Apply → Prove → Release → Destroy → Rebuild
```

## 2. Tool and Region

We will use Terraform.

All resources will be created in the assigned AWS region:

```text
AWS account: 827478161993
Region: us-west-1
Environment: lab
```

Terraform and the AWS provider will be pinned in code. The `.terraform.lock.hcl` file should be committed after `terraform init`.

## 3. Naming Standard

All Terraform-created workload resources will use the prefix:

```text
devops-g3-iac-
```

Examples:

```text
devops-g3-iac-vpc
devops-g3-iac-alb
devops-g3-iac-cluster
devops-g3-iac-order
devops-g3-iac-inventory
devops-g3-iac-payment
```

Reason:

The existing console-created resources already use `devops-g3-*`. The `iac` segment prevents name collisions and makes it clear which resources are managed by Terraform.

## 4. Target Architecture

The application flow is:

```text
User
  ↓
Internet-facing Application Load Balancer
  ↓
Service A: Order
  ↓
Service B: Inventory
  ↓
Service C: Payment
```

Only the ALB is public.

The ECS services run in private app subnets and receive no public IPs.

```text
Internet → ALB allowed
Internet → Order / Inventory / Payment directly denied
```

## 5. VPC Design

Terraform will create a new custom VPC:

```text
Name: devops-g3-iac-vpc
CIDR: 10.30.0.0/16
```

This CIDR is separate from the current default VPC range used by the manual setup:

```text
Default VPC: 172.31.0.0/16
Terraform VPC: 10.30.0.0/16
```

## 6. Subnet Design

The environment will use at least two Availability Zones.

**Availability Zones in `us-west-1`:** This region provides **`us-west-1a`** and **`us-west-1c`** only (there is no `us-west-1b`). Subnet names use `-a` / `-c` suffixes to match the AZ.

We will create two public subnets and two private app subnets.

| Subnet name | AZ | CIDR | Purpose |
|---|---|---|---|
| `devops-g3-iac-public-a` | `us-west-1a` | `10.30.0.0/24` | ALB |
| `devops-g3-iac-public-c` | `us-west-1c` | `10.30.1.0/24` | ALB |
| `devops-g3-iac-app-a` | `us-west-1a` | `10.30.10.0/24` | ECS Fargate tasks |
| `devops-g3-iac-app-c` | `us-west-1c` | `10.30.11.0/24` | ECS Fargate tasks |

Fargate uses `awsvpc` networking:

```text
1 ECS task = 1 ENI = 1 private IP
```

The `/24` subnet size gives enough room for task ENIs, VPC endpoint ENIs, and rolling deployments.

## 7. Public and Private Routing

A subnet is public or private because of its route table, not because of its name.

Public subnet route:

```text
10.30.0.0/16 → local
0.0.0.0/0   → Internet Gateway
```

Private app subnet route:

```text
10.30.0.0/16 → local
S3 traffic   → S3 Gateway Endpoint
AWS service traffic → Interface VPC Endpoints
```

The public subnets are for the ALB.

The private app subnets are for ECS tasks.

## 8. Egress Decision: VPC Endpoints

We will use VPC endpoints instead of NAT Gateway for AWS service egress.

Private ECS tasks need outbound access to AWS services for:

- pulling container images from ECR;
- downloading ECR image layers from S3;
- sending logs to CloudWatch Logs;
- using AWS identity/token calls through STS.
- opening ECS Exec sessions through SSM Messages.

Required endpoints:

| Endpoint | Type | Why it is needed |
|---|---|---|
| ECR API | Interface | ECR auth and API calls |
| ECR Docker | Interface | Docker image manifest pulls |
| CloudWatch Logs | Interface | Container log delivery |
| STS | Interface | Temporary AWS role credentials |
| SSM Messages | Interface | ECS Exec control/data channels for private tasks |
| S3 | Gateway | ECR image layer downloads |

Important note:

ECR image pulls need the S3 Gateway endpoint because ECR image layers are stored through S3. Missing the S3 endpoint can cause private ECS tasks to fail pulling images.

We will not use NAT Gateway unless the application later needs outbound access to third-party internet services.

## 9. ALB Design

Terraform will create an internet-facing ALB:

```text
Name: devops-g3-iac-alb
Listener: HTTP port 80
Target group: devops-g3-iac-order-tg
Target type: ip
Health check path: /health
```

Only Service A / Order is registered in the ALB target group.

Traffic path:

```text
Internet → ALB:80 → Order private task IP:3001
```

## 10. ECS Design

Terraform will create:

```text
ECS cluster: devops-g3-iac-cluster
```

Services:

| Service | Terraform name | Port | Desired count | Public? |
|---|---|---:|---:|---|
| Order | `devops-g3-iac-order` | 3001 | 2 | Via ALB only |
| Inventory | `devops-g3-iac-inventory` | 3002 | 1 | No |
| Payment | `devops-g3-iac-payment` | 3003 | 1 | No |

All ECS services must use:

```text
launch type: FARGATE
network mode: awsvpc
assignPublicIp: false
CloudWatch Logs enabled
ECS Exec enabled
deployment circuit breaker enabled
automatic rollback enabled
```

## 11. Service Discovery

The environment will use ECS Service Connect for service-to-service discovery.

Namespace:

```text
group3.internal
```

Services must call each other by service name, not task IP.

Expected internal calls:

```text
order → inventory
inventory → payment
```

Potential risk:

The existing console environment may already use `group3.internal`. The Terraform environment will create its own private namespace in the new VPC and reference it by ARN. If AWS rejects duplicate namespace creation, the team will document the issue and agree on a safe deviation.

Namespace coexistence details are documented in `docs/TERRAFORM-SERVICE-CONNECT-NAMESPACE.md`.

## 12. Security Group Traffic Contract

Security group rules must reference other security groups, not task IP addresses.

Allowed traffic:

| Source | Destination | Port | Result |
|---|---|---:|---|
| Internet | ALB SG | 80 | Allow |
| ALB SG | Order SG | 3001 | Allow |
| Order SG | Inventory SG | 3002 | Allow |
| Inventory SG | Payment SG | 3003 | Allow |

Denied traffic:

| Source | Destination | Result |
|---|---|---|
| Internet | Order directly | Deny |
| Internet | Inventory directly | Deny |
| Internet | Payment directly | Deny |
| Order | Payment directly | Deny |

When wiring service modules, pass ingress rules as a map with stable caller-chosen keys:

```hcl
ingress_rules = {
  from-alb = {
    description              = "ALB to order"
    from_port                = 3001
    to_port                  = 3001
    protocol                 = "tcp"
    source_security_group_id = module.alb.alb_security_group_id
  }
}
```

Callback decision:

If the application keeps the existing Payment → Order `/confirm` callback, it must be documented and explicitly allowed:

| Source | Destination | Port | Result |
|---|---|---:|---|
| Payment SG | Order SG | 3001 | Allow for callback only |

Because the callback closes the dependency chain (`order → inventory → payment → order`), do not put this callback rule inside the reusable `ecs-service` module input. Add it as a standalone root-level rule after all service modules exist:

```hcl
resource "aws_vpc_security_group_ingress_rule" "payment_to_order_confirm" {
  security_group_id            = module.order.security_group_id
  referenced_security_group_id = module.payment.security_group_id
  from_port                    = 3001
  to_port                      = 3001
  ip_protocol                  = "tcp"
  description                  = "Payment confirm callback to order"
}
```

If the team chooses a strict A → B → C flow, the callback path should be removed or disabled for this Terraform build.

## 13. Remote State Backend

Terraform state will be stored remotely in S3.

The backend is created separately in:

```text
infra/bootstrap/
```

The bootstrap stack creates an S3 bucket with:

- versioning enabled;
- encryption enabled;
- public access blocked;
- S3 lockfile state locking enabled (`use_lockfile = true`, no DynamoDB table).

**Implemented (Minage):**

| Item | Value |
|------|-------|
| Bucket | `devops-g3-tfstate-827478161993-uswest1` |
| Bootstrap stack | `infra/bootstrap/` (local state for bucket only) |
| Workload backend | `infra/environments/lab/backend.tf` |
| State key | `workload/lab/terraform.tfstate` |
| Locking | S3 native lockfile |

The workload environment will use:

```text
infra/environments/lab/
```

The backend bucket must survive workload destroy.

## 14. Repository Structure

The required Terraform structure is:

```text
infra/
├── bootstrap/
├── environments/
│   └── lab/
├── modules/
│   ├── network/
│   ├── alb/
│   ├── ecs-platform/
│   └── ecs-service/
└── tests/
```

Purpose of each folder:

| Folder | Purpose |
|---|---|
| `infra/bootstrap/` | Creates the S3 backend for Terraform state |
| `infra/environments/lab/` | Main lab environment that connects all modules |
| `infra/modules/network/` | VPC, subnets, route tables, Internet Gateway, VPC endpoints |
| `infra/modules/alb/` | ALB, listener, target group |
| `infra/modules/ecs-platform/` | ECS cluster, Service Connect namespace, shared IAM roles |
| `infra/modules/ecs-service/` | Reusable ECS service module for order, inventory, payment |
| `infra/tests/` | Terraform architecture tests |

## 15. Terraform Files to Create

Bootstrap:

```text
infra/bootstrap/
├── versions.tf
├── providers.tf
├── main.tf
└── outputs.tf
```

Lab environment:

```text
infra/environments/lab/
├── versions.tf
├── providers.tf
├── backend.tf
├── variables.tf
├── terraform.tfvars.example
├── main.tf
└── outputs.tf
```

Modules:

```text
infra/modules/network/
├── variables.tf
├── main.tf
└── outputs.tf

infra/modules/alb/
├── variables.tf
├── main.tf
└── outputs.tf

infra/modules/ecs-platform/
├── variables.tf
├── main.tf
└── outputs.tf

infra/modules/ecs-service/
├── variables.tf
├── main.tf
└── outputs.tf
```

Tests:

```text
infra/tests/
└── architecture.tftest.hcl
```

## 16. Architecture Tests

The environment will include architecture rules as code.

We will add checks/tests to detect invalid designs such as:

- ECS task receives a public IP;
- ALB spans fewer than two AZs;
- target group type is not `ip`;
- app port is open to `0.0.0.0/0`;
- required tags are missing;
- wrong AWS region is selected;
- image tag is `latest`;
- Service A can reach Service C directly.

## 17. Application Release Model

Images must use immutable Git SHA tags.

Not allowed:

```text
latest
```

Allowed:

```text
a1b2c3d
```

Release flow:

```text
Application change
  ↓
Tests
  ↓
Build SHA-tagged image
  ↓
Push image to ECR
  ↓
Update Terraform image SHA variable
  ↓
terraform plan
  ↓
review
  ↓
terraform apply
  ↓
ECS rolling deployment
  ↓
GET /version proves deployed SHA
```

## 18. Required Runtime Evidence

After apply, the environment must prove:

- Internet → ALB succeeds;
- ALB → Order succeeds;
- Order → Inventory by service name succeeds;
- Inventory → Payment by service name succeeds;
- Internet → Order/Inventory/Payment directly denied;
- Order → Payment directly denied;
- ECS tasks are running and healthy;
- Order tasks are placed across two AZs;
- ALB targets are healthy;
- deployed Git SHA is visible at runtime;
- CloudWatch logs exist for all services;
- ECS Exec works;
- ECS tasks have no public IPs;
- route tables prove VPC endpoint egress.

## 19. Immediate Next Step

Gate 1 design items below should be peer-reviewed before the first **workload** `terraform apply`.

**Platform progress (Minage):**

| Step | Status |
|------|--------|
| Bootstrap S3 bucket | Done |
| Lab remote backend + init | Done |
| Release model + SHA validation | Done — see `docs/TERRAFORM-RELEASE.md` |
| Network / ALB / ECS modules | Done — reusable module foundations added |
| Lab `main.tf` wiring | Pending — after modules |

After review, implementation should continue in this order:

```text
1. bootstrap stack                    ✅
2. network module                     ✅
3. ALB module                         ✅
4. ECS platform module                ✅
5. reusable ECS service module        ✅
6. lab environment wiring
7. architecture tests
8. runtime evidence
```

## 20. Architecture Decision Cards

Each card answers: What risk are we reducing? What trade-off are we accepting? Which Well-Architected pillar? What evidence proves it works?

### Card 1 — Two Availability Zones (owner: Lwam)

| Question | Answer |
|----------|--------|
| Risk reduced | Single-AZ outage removes all Order tasks or ALB capacity in one zone |
| Trade-off | More subnets, endpoints, and cross-AZ traffic to manage |
| Pillar | Reliability |
| Evidence | Order `desired_count = 2` with tasks in `us-west-1a` and `us-west-1c`; ALB spans both public subnets |

### Card 2 — Private Fargate tasks (owner: Lwam)

| Question | Answer |
|----------|--------|
| Risk reduced | Direct internet reachability to application ports on tasks |
| Trade-off | Requires VPC endpoints (or NAT) for ECR, Logs, STS; no public IP for outbound internet |
| Pillar | Security |
| Evidence | `assign_public_ip = false`; ENI `PublicIp: null`; internet curl to task IP fails |

### Card 3 — Security-group references (owner: Lwam)

| Question | Answer |
|----------|--------|
| Risk reduced | Stale IP allowlists when ECS replaces tasks; overly broad `0.0.0.0/0` on app ports |
| Trade-off | Every allowed hop must be modeled explicitly as SG → SG rules |
| Pillar | Security |
| Evidence | SG matrix in §12; runtime Gate 2 trio; architecture tests on A→B, B→C, A→C |

### Card 4 — Immutable Git SHA (owner: Minage)

See full card in `docs/TERRAFORM-RELEASE.md` §7.

| Question | Answer |
|----------|--------|
| Risk reduced | Untraceable deploys; `latest` tag drift |
| Trade-off | Every release requires IaC variable update + plan/apply |
| Pillar | Operational Excellence |
| Evidence | `variables.tf` rejects `latest`; ALB `/health` shows deployed SHA |

### Card 5 — Remote, versioned, locked state (owner: Minage)

| Question | Answer |
|----------|--------|
| Risk reduced | Lost or divergent local state; concurrent applies corrupting infrastructure; no team-wide source of truth |
| Trade-off | Bootstrap S3 bucket must be maintained separately; bootstrap uses local state once; IAM permissions for state bucket access |
| Pillar | Operational Excellence |
| Evidence | State object at `s3://devops-g3-tfstate-827478161993-uswest1/workload/lab/terraform.tfstate`; bucket versioning enabled; `terraform plan` prints `Releasing state lock`; workload destroy leaves bucket intact; `.terraform.lock.hcl` committed for provider pin |

**Prevention encoded in repo:**

- Separate `infra/bootstrap/` stack excluded from workload destroy
- `backend.tf` with `encrypt = true` and `use_lockfile = true`
- `.gitignore` blocks `*.tfstate` and `*.tfvars` (not example)
- Pinned Terraform `>= 1.11` and AWS provider `= 6.56.0`

## 21. Gate 1 Peer Review Checklist

Review before first workload `terraform apply`:

- [ ] Subnet AZs use `us-west-1a` and `us-west-1c` (not `1b`)
- [ ] VPC CIDR `10.30.0.0/16` does not overlap default VPC `172.31.0.0/16`
- [ ] All IaC names use `devops-g3-iac-*` prefix
- [ ] SG matrix matches assignment traffic contract (§12)
- [ ] S3 gateway endpoint included in egress design (§8)
- [ ] Bootstrap bucket survives workload destroy (§13)
- [ ] Five architecture decision cards complete (§20)
- [ ] Three predicted failure scenarios documented (service owners)
- [ ] Service Connect namespace coexistence verified (§11)

**Peer review sign-off:**

| Reviewer | Date | Approved |
|----------|------|----------|
| | | ⬜ |
