# Gate 1 (IaC) — Service B: inventory

**Group:** group-3
**Owner:** Joyce (Service B — inventory)
**Assignment:** 1 — Greenfield ECS Fargate with Terraform/OpenTofu
**Phase:** Gate 1 design (paper gate; no AWS resources created yet)
**Naming:** IaC resources use the `devops-g3-iac-*` discriminator so they coexist
with the still-running console `devops-g3-*` cluster (two clusters live Wednesday).

Scenario role **Service B** = our **inventory** service. It sits in the middle of
the request chain: `Internet -> ALB -> order (A) -> inventory (B) -> payment (C)`.
Inventory is private — it is never reachable from the internet, only from order.

---

## 1. Service B input spec

These are the values I hand to the shared `modules/ecs-service` module when it is
instantiated for inventory.

| Input | Value | Note |
|---|---|---|
| Service name | `inventory` | scenario Service B |
| App / container port | `3002` | carries over from console task def |
| Desired count | `1` | single task; scale is not being tested here |
| ALB-registered? | **no** | only order (A) is behind the ALB |
| `assign_public_ip` | `false` | private task, no public IP (see decision card) |
| Subnets | private app subnets (`app-a`, `app-b`) | Fargate ENIs land here |
| Security group | `devops-g3-iac-inventory-sg` | see traffic rules below |
| Service Connect | enabled; discovery name `inventory` | reached as `inventory:3002` |
| Namespace | `group3.internal` (referenced by ARN) | shared IaC namespace |
| Image | `…/devops-g3-iac-inventory:<git-sha>` | immutable SHA tag, never `latest` |
| ECR repo | `devops-g3-iac-inventory` | `IMMUTABLE` tag mutability |
| Log group | `/ecs/devops-g3-iac/inventory` | prefix-clean and distinct from console |
| Health check | `/health` on 3002 | task marked healthy only when this passes |
| Build platform | `linux/amd64` | avoid arm-Mac exec-format errors |

**Tags** (required on the resource — the tags test checks these):

| Key | Value |
|---|---|
| `project` | devops-Ecommerce |
| `group` | group-3 |
| `owner` | inventory-owner |
| `environment` | lab |

### Traffic contract for Service B (security-group references only — no CIDRs)

| Direction | From SG | To SG | Port | Result |
|---|---|---|---|---|
| Ingress | `devops-g3-iac-order-sg` (A) | `devops-g3-iac-inventory-sg` (B) | 3002 | **Allow** |
| Egress | `devops-g3-iac-inventory-sg` (B) | `devops-g3-iac-payment-sg` (C) | 3003 | **Allow** |
| Ingress | Internet `0.0.0.0/0` | `devops-g3-iac-inventory-sg` (B) | any | **Deny** (no rule exists) |

Inventory therefore has exactly one way in (from order) and one way out (to
payment). No rule references the internet, so the internet-direct path is denied
by construction, not by an allow-list I have to maintain.

---

## 2. Predicted broken edge: order (A) -> inventory (B)

Gate 1 asks each owner to predict one dependency edge that will break, its
user-visible symptom, and the AWS evidence that proves the cause. This becomes an
architecture test and feeds the failure-prediction badge.

**Predicted failure:** order cannot reach inventory by its Service Connect name.

**Most likely root cause:** the inventory security group is missing the ingress
rule that allows `devops-g3-iac-order-sg` on port 3002 (or the rule points at the
wrong port / wrong source SG). Discovery resolves the name, but the packet is
dropped at the security group.

**User-visible symptom:** a client request reaches the ALB and order returns an
error (timeout or 5xx) at the step where it calls `http://inventory:3002`. The
relay stalls at the A -> B hop; payment is never reached.

**AWS evidence I would collect to confirm it (two independent signals):**

1. **order logs (CloudWatch `/ecs/devops-g3-iac/order`)** — a connection
   timeout / "connection refused" to `inventory:3002`, i.e. the name *did*
   resolve but the connection did not complete. This rules out a discovery/DNS
   problem and points at the network path.
2. **inventory security group** — describing `devops-g3-iac-inventory-sg` shows
   **no ingress rule** referencing `devops-g3-iac-order-sg` on 3002. That
   missing rule is the dropped-packet cause.

Supporting checks: inventory task is `RUNNING` and healthy (so the app is up and
it is a path problem, not a crash), and Service Connect lists `inventory` in
`group3.internal` (so discovery is fine). The failure is isolated to the SG edge.

**Prevention encoded as a test:** an architecture test asserts the
order-SG -> inventory-SG rule on 3002 exists, so this edge cannot silently go
missing in a future change.

---

## 3. Decision card — Private Fargate tasks (inventory has no public IP)

| Question | Answer |
|---|---|
| **Decision** | Run the inventory task with `assign_public_ip = false` in private subnets; it is reachable only from order via Service Connect. |
| **Risk we reduce** | A public IP on the task would expose inventory (and its 3002 port) directly to the internet, bypassing the ALB and the intended `order -> inventory` boundary — a wide, unnecessary attack surface. |
| **Trade-off we accept** | The task has no direct outbound path to the internet, so image pulls and logs must go through VPC endpoints (or a NAT). It is also slightly harder to test directly — I must exercise it through order rather than hitting it from my laptop. |
| **Well-Architected pillar** | Security (least exposure / minimize attack surface). Secondary: Cost Optimization, since staying off public IPs pairs with the endpoint-based egress design. |
| **Evidence it works** | (1) The ECS service network config shows `assignPublicIp: DISABLED` and the task ENI has no public IP. (2) A runtime deny-proof: an attempt to reach inventory directly from the internet fails, while `order -> inventory:3002` succeeds. (3) An architecture test asserts `assign_public_ip == false`, failing the build if anyone flips it. |

**Ties to the acceptance contract:** this decision is what makes the
`Internet -> inventory direct = DENIED` line in the runtime contract true, and it
is proven two ways (config inspection + live deny attempt), as required.

---

## Dependencies / what I am waiting on

- ⛔ Gate 1 sign-off (this doc reviewed) before any apply.
- `modules/network` (Lwam) — gives me the private subnet IDs and the endpoint/NAT
  egress path my task depends on.
- `modules/ecs-service` skeleton (Lwam + owners) — I instantiate it for inventory;
  I do not author it.
- `modules/ecs-platform` (Minage) — gives me the `group3.internal` namespace ARN,
  shared IAM roles, and the log-group naming convention.
