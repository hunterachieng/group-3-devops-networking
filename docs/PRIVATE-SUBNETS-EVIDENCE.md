# Private Subnets Migration — Runtime & Security Proof

**Cluster:** `devops-g3-cluster` | **Region:** `us-west-1` | **Account:** `827478161993`  
**VPC:** `vpc-037dbe66e621f6f13` | **Namespace:** `group3.internal` | **ALB:** `devops-g3-alb`

This assignment moves Service B (Inventory) and Service C (Payment) into private
subnets with a NAT Gateway and private route table. Security boundaries must still
hold at runtime after migration. Every claim is backed by at least two evidence
types: runtime `curl`/exec output and configuration proof (ECS network config, ENI,
route table).

---

## 1. Summary — infrastructure + Gate 2 re-verification

| # | Test | Expected | Result |
|---|---|---|---|
| 1 | Private subnets exist (2 AZs) | `devops-g3-private-us-west-1a/1c` | ✅ PASS |
| 2 | NAT Gateway available | State `available` | ✅ PASS |
| 3 | Private route table routes to NAT | `0.0.0.0/0 → nat-0dc5e7e21ddbb5a76` | ✅ PASS |
| 4 | Inventory `assignPublicIp` | `DISABLED` | ✅ PASS |
| 5 | Payment `assignPublicIp` | `DISABLED` | ✅ PASS |
| 6 | Inventory task has no public IP | `PublicIp: null` | ✅ PASS |
| 7 | Payment task has no public IP | `PublicIp: null` | ✅ PASS |
| 8 | All services RUNNING | runningCount == desiredCount | ✅ PASS |
| 9 | A → B (`order` → `inventory:3002`) | 200 | ✅ PASS |
| 10 | B → C (`inventory` → `payment:3003`) | 200 | ✅ PASS |
| 11 | A → C (`order` → `payment:3003`) | denied / timeout | ✅ PASS |
| 12 | Full checkout via ALB | `"outcome": "success"` | ✅ PASS |

---

## 2. Evidence table

Two evidence types per claim:

- **Runtime evidence:** live `curl`, ECS Exec output, or checkout JSON.
- **Configuration evidence:** ECS `assignPublicIp`, ENI public IP, subnet IDs, route table.

| Test | Expected | Evidence 1 — runtime | Evidence 2 — configuration | Result |
|---|---|---|---|---|
| Inventory in private subnet | no public IP | ENI query → `PublicIp: null` (§5.3) | ECS `assignPublicIp: DISABLED` + private subnet ID (§5.2) | ✅ |
| Payment in private subnet | no public IP | ENI query → `PublicIp: null` (§5.4) | ECS `assignPublicIp: DISABLED` + private subnet ID (§5.2) | ✅ |
| Services healthy | all RUNNING | Checkout `"outcome": "success"` (§5.8) | `describe-services` table 2/2, 1/1, 1/1 (§5.1) | ✅ |
| A → B | 200 | Exec order → `curl inventory:3002/health` → `200` (§5.5) | Inventory SG allows order-sg on 3002 (Gate 2 §4.7) | ✅ |
| B → C | 200 | Exec inventory → `curl payment:3003/health` → `200` (§5.6) | Payment SG allows inventory-sg on 3003 (Gate 2 §4.7) | ✅ |
| A → C | denied | Exec order → `curl payment:3003/health` → timeout (§5.7) | No order-sg → payment-sg:3003 rule (Gate 2 §4.8) | ✅ |
| Internet → B/C | no direct path | B/C ENIs have `PublicIp: null` — no routable task IP (§5.3–5.4) | Private subnets + `assignPublicIp: DISABLED` (§5.1–5.2) | ✅ |

---

## 3. Why each result is what it is

- **Inventory and Payment have no public IP** because ECS services were moved to
  private subnets (`subnet-00276e31b96224308`, `subnet-08917cfb0bc03f01f`) with
  `assignPublicIp: DISABLED`. Tasks receive only a private RFC1918 address.
- **Outbound traffic (ECR image pulls, etc.)** exits via the NAT Gateway
  (`nat-0dc5e7e21ddbb5a76`) through the private route table (`rtb-0dfcf9a1e8988b52a`).
- **Order stays in public subnets** with `assignPublicIp: ENABLED` so the ALB can
  reach it; Inventory and Payment remain reachable only via Service Connect inside the VPC.
- **A → B and B → C still succeed** because Service Connect and security-group rules
  are unchanged — only the subnet placement changed.
- **A → C still fails** because there is still no SG rule allowing `order-sg → payment-sg:3003`.
- **Internet → B/C is stronger than before:** tasks no longer have a public IP at all,
  so direct task-IP curls from the Internet are impossible even if SG rules existed.

---

## 4. Resource inventory (after migration)

| Resource | ID / value |
|---|---|
| VPC | `vpc-037dbe66e621f6f13` |
| Private subnet us-west-1a | `subnet-00276e31b96224308` (`172.31.100.0/24`, `devops-g3-private-us-west-1a`) |
| Private subnet us-west-1c | `subnet-08917cfb0bc03f01f` (`172.31.101.0/24`, `devops-g3-private-us-west-1c`) |
| Public subnet us-west-1a | `subnet-0780a6a8bf1120301` |
| Public subnet us-west-1c | `subnet-05505b0c5d0b340fd` |
| NAT Gateway | `nat-0dc5e7e21ddbb5a76` (public IP `52.53.85.176`) |
| Private route table | `rtb-0dfcf9a1e8988b52a` |
| Inventory security group | `sg-050dcd78ace8718c3` |
| Payment security group | `sg-08ba2bfa6315a8c0e` |

Full snapshot: `infra/vpc/network-state.json`

---

## 5. Reproduction commands + captured output

### 5.0 Setup

```bash
export AWS_REGION=us-west-1
export AWS_PAGER=""
export CLUSTER=devops-g3-cluster
export PRIV_A=subnet-00276e31b96224308
export PRIV_B=subnet-08917cfb0bc03f01f
export PAY_SG=sg-08ba2bfa6315a8c0e
```

### 5.1 All services running + assignPublicIp (expect order ENABLED, B/C DISABLED)

```bash
aws ecs describe-services --cluster $CLUSTER \
  --services devops-g3-order devops-g3-inventory devops-g3-payment \
  --region us-west-1 \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount,assignPublicIp:networkConfiguration.awsvpcConfiguration.assignPublicIp}' \
  --output table
```

```txt
-----------------------------------------------------------------
|                       DescribeServices                        |
+-----------------+----------+-----------------------+----------+
| assignPublicIp  | desired  |         name          | running  |
+-----------------+----------+-----------------------+----------+
|  ENABLED        |  2       |  devops-g3-order      |  2       |
|  DISABLED       |  1       |  devops-g3-inventory  |  1       |
|  DISABLED       |  1       |  devops-g3-payment    |  1       |
+-----------------+----------+-----------------------+----------+
```

### 5.2 Payment migration — network config after update (configuration evidence)

```bash
aws ecs update-service --cluster $CLUSTER --service devops-g3-payment \
  --region us-west-1 \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIV_A,$PRIV_B],securityGroups=[$PAY_SG],assignPublicIp=DISABLED}" \
  --force-new-deployment

aws ecs wait services-stable --cluster $CLUSTER --services devops-g3-payment --region us-west-1
echo "Payment stable"
```

```txt
Payment stable
```

Payment service network configuration (after migration):

```json
"networkConfiguration": {
    "awsvpcConfiguration": {
        "subnets": [
            "subnet-08917cfb0bc03f01f",
            "subnet-00276e31b96224308"
        ],
        "securityGroups": [
            "sg-08ba2bfa6315a8c0e"
        ],
        "assignPublicIp": "DISABLED"
    }
}
```

### 5.3 Inventory task ENI — no public IP (expect PublicIp null)

```bash
TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-inventory \
  --query 'taskArns[0]' --output text --region us-west-1)

ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --region us-west-1 \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)

aws ec2 describe-network-interfaces --network-interface-ids $ENI --region us-west-1 \
  --query 'NetworkInterfaces[0].{PrivateIp:PrivateIpAddress,PublicIp:Association.PublicIp,SubnetId:SubnetId}' \
  --output json
```

```json
{
    "PrivateIp": "172.31.100.87",
    "PublicIp": null,
    "SubnetId": "subnet-00276e31b96224308"
}
```

### 5.4 Payment task ENI — no public IP (expect PublicIp null)

```bash
TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-payment \
  --query 'taskArns[0]' --output text --region us-west-1)

ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK --region us-west-1 \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)

aws ec2 describe-network-interfaces --network-interface-ids $ENI --region us-west-1 \
  --query 'NetworkInterfaces[0].{PrivateIp:PrivateIpAddress,PublicIp:Association.PublicIp,SubnetId:SubnetId}' \
  --output json
```

```json
{
    "PrivateIp": "172.31.100.99",
    "PublicIp": null,
    "SubnetId": "subnet-00276e31b96224308"
}
```

### 5.5 A → B (expect 200)

```bash
export ORDER_TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-order \
  --query 'taskArns[0]' --output text --region us-west-1)

aws ecs execute-command --cluster $CLUSTER --task $ORDER_TASK \
  --container order --interactive --command "/bin/sh" --region us-west-1

# inside the container:
curl -i --max-time 5 http://inventory:3002/health
```

```txt
HTTP/1.1 200 OK
server: envoy
date: Thu, 30 Jul 2026 10:28:17 GMT
content-type: application/json
content-length: 66
x-envoy-upstream-service-time: 124

{"service":"inventory-service","status":"ok","version":"41eb453"}
```

### 5.6 B → C (expect 200)

```bash
export INV_TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-inventory \
  --query 'taskArns[0]' --output text --region us-west-1)

aws ecs execute-command --cluster $CLUSTER --task $INV_TASK \
  --container inventory --interactive --command "/bin/sh" --region us-west-1

# inside the container:
curl -i --max-time 5 http://payment:3003/health
```

```txt
HTTP/1.1 200 OK
server: envoy
date: Thu, 30 Jul 2026 10:55:48 GMT
content-type: application/json
content-length: 64
x-envoy-upstream-service-time: 116

{"service":"payment-service","status":"ok","version":"f16e6ef"}
```

### 5.7 A → C (expect timeout — Gate 2 denial still holds)

```bash
aws ecs execute-command --cluster $CLUSTER --task $ORDER_TASK \
  --container order --interactive --command "/bin/sh" --region us-west-1

# inside the container:
curl -i --max-time 5 http://payment:3003/health
```

```txt
curl: (28) Operation timed out after 5001 milliseconds with 0 bytes received
```

### 5.8 Full checkout via ALB (expect success end-to-end)

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names devops-g3-alb \
  --query 'LoadBalancers[0].DNSName' --output text --region us-west-1)

curl -s -X POST "http://${ALB_DNS}/checkout" \
  -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}' | python3 -m json.tool
```

```json
{
    "order_id": "ORD-D50D0FC9",
    "outcome": "success",
    "pipeline": {
        "downstream": {
            "amount": 3500,
            "confirm": "sent",
            "order_id": "ORD-D50D0FC9",
            "outcome": "success",
            "request_id": "2e3bbb5d-6cf2-4ba0-9f15-8287e4a38a5d",
            "service": "payment-service"
        },
        "order_id": "ORD-D50D0FC9",
        "outcome": "success",
        "request_id": "2e3bbb5d-6cf2-4ba0-9f15-8287e4a38a5d",
        "service": "inventory-service"
    },
    "request_id": "2e3bbb5d-6cf2-4ba0-9f15-8287e4a38a5d",
    "service": "order-service"
}
```

---

## 6. Per-service network placement (live config)

| Service | Subnets | assignPublicIp | Private IP (sample) | Public IP |
|---|---|---|---|---|
| devops-g3-order | public (`subnet-0780…`, `subnet-0550…`) | ENABLED | (ALB-backed) | yes |
| devops-g3-inventory | private (`subnet-00276…`, `subnet-08917…`) | DISABLED | `172.31.100.87` | null |
| devops-g3-payment | private (`subnet-00276…`, `subnet-08917…`) | DISABLED | `172.31.100.99` | null |

Gate 2 security-group contract unchanged — see `docs/GATE2-EVIDENCE.md` §5.

---

## 7. Definition of done — private subnets migration

- [x] Private subnets `devops-g3-private-us-west-1a` and `devops-g3-private-us-west-1c` in use
- [x] NAT Gateway `nat-0dc5e7e21ddbb5a76` state `available`
- [x] Private route table `rtb-0dfcf9a1e8988b52a` routes `0.0.0.0/0 → NAT`
- [x] Inventory ECS service uses private subnets, `assignPublicIp=DISABLED`
- [x] Payment ECS service uses private subnets, `assignPublicIp=DISABLED`
- [x] Inventory and Payment tasks RUNNING (no pull errors after NAT in place)
- [x] No public IP on Inventory or Payment ENIs
- [x] Gate 2 trio re-verified: A→B ✅, A→C denied ✅, B→C ✅
- [x] Checkout via ALB succeeds (`outcome: success`, `confirm: sent`)
- [x] `infra/vpc/network-state.json` committed
- [x] Live output pasted into §5 blocks

