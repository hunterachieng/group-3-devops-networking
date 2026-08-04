# Terraform Gate 2 — Runtime Evidence (IaC stack)

Live allow/deny proof for the `devops-g3-iac-*` stack. Two evidence types per
critical claim: **(a)** the security-group rule as configured, and **(b)** live
traffic captured via ECS Exec.

- **Cluster:** `devops-g3-iac-cluster`
- **Region:** `us-west-1`
- **Namespace:** `group3.internal` (Service Connect)
- **Captured:** 2026-08-04
- **Raw capture:** `phase5-evidence/gate2-serviceconnect-hops.txt`

---

## 1. Security-group matrix (live)

Verified with `aws ec2 describe-security-group-rules` against each service SG.
Matches the traffic contract in [TERRAFORM-GATE1-DESIGN.md](TERRAFORM-GATE1-DESIGN.md) §12.

| SG | ID |
|---|---|
| alb | `sg-0e87c3ed51b121ff8` |
| order | `sg-01df35d3d4d45e6ae` |
| inventory | `sg-0271101ffd19f4d95` |
| payment | `sg-0cb3980ac0c44b94e` |

| Edge | Rule (destination SG ingress) | Result |
|---|---|---|
| Internet → ALB :80 | alb-sg ← 0.0.0.0/0 | Allow |
| ALB → Order :3001 | order-sg ← alb-sg — "ALB to order" | Allow |
| Order → Inventory :3002 | inventory-sg ← order-sg | Allow |
| Inventory → Payment :3003 | payment-sg ← inventory-sg **only** | Allow |
| Payment → Order :3001 | order-sg ← payment-sg — "Payment confirm callback to order" | Allow (callback) |
| **Order → Payment (direct)** | payment-sg has **no** rule from order-sg | **Deny (by omission)** |

Payment service health at capture time: `desiredCount=1 runningCount=1` — so the
A→C failure below is an **intentional SG deny, not an outage**.

---

## 2. A→B allow — order → inventory:3002

ECS Exec into order task `3062760d8b79496fade985e2887f92bb`, container `order`:

```
$ curl -s http://inventory:3002/health
{"service":"inventory-service","status":"ok","version":"41eb453"}
$ curl -s http://inventory:3002/version
{"service":"inventory","status":"ok","version":"41eb453"}
```

## 3. B→C allow — inventory → payment:3003

ECS Exec into inventory task `0d3873664a2047288982780ab0b6afb6`, container `inventory`:

```
$ curl -s http://payment:3003/health
{"service":"payment-service","status":"ok","version":"f16e6ef"}
$ curl -s http://payment:3003/version
{"service":"payment","status":"ok","version":"f16e6ef"}
```

## 4. A→C deny — order → payment:3003

ECS Exec into order task `3062760d8b79496fade985e2887f92bb`, container `order`:

```
$ curl -s http://payment:3003/health
upstream request timeout
$ curl -s http://payment:3003/version
upstream request timeout
```

The Service Connect Envoy sidecar returns `upstream request timeout` because the
packet is silently dropped at payment's ingress — payment-sg accepts only
`inventory-sg` on 3003. Payment itself is healthy (proven by §3), so this is the
security boundary working as designed.

---

## 5. Summary

| Edge | Result | Proof (a) config | Proof (b) live traffic |
|---|---|---|---|
| A→B order→inventory:3002 | Allow | inventory-sg ← order-sg | §2 — 200 JSON |
| B→C inventory→payment:3003 | Allow | payment-sg ← inventory-sg | §3 — 200 JSON |
| A→C order→payment:3003 | **Deny** | no order-sg rule on payment-sg | §4 — timeout, payment healthy |
| Payment→Order:3001 callback | Allow | order-sg ← payment-sg | §1 SG rule live |

**Conclusion:** the live security groups match the documented traffic contract on
every edge. No SG defect. The only nuance surfaced during testing was that an
order-side timeout alone cannot distinguish *deny* from *outage* — resolved by the
B→C positive proof in §3, which confirms payment is healthy.
