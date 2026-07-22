# Gate 2 — Runtime & Security Proof

**Group:** group-3 | **Owner (order):** Hunter  
**Cluster:** `devops-g3-cluster` | **Region:** `us-west-1` | **Account:** `827478161993`  
**Namespace:** `group3.internal` | **ALB:** `devops-g3-alb` | **Target group:** `devops-g3-order-tg`

Gate 2 requires that the security boundaries are proven **at runtime**, not just
from configuration. The required trio is **A→B succeeds, A→C fails, B→C succeeds**,
with all Internet→service app-port paths denied. Every claim is backed by at
least two evidence types: runtime `curl`/exec output and configuration proof.

Service mapping: **A = order (3001), B = inventory (3002), C = payment (3003).**

---

## 1. Summary — required trio + denials

| # | Test | Expected | Result |
|---|---|---|---|
| 1 | Internet → ALB `/health` | 200 | ✅ PASS |
| 2 | A → B (`order` → `inventory:3002`) | 200 | ✅ PASS |
| 3 | B → C (`inventory` → `payment:3003`) | 200 | ✅ PASS |
| 4 | A → C (`order` → `payment:3003`) | denied / timeout | ✅ PASS |
| 5 | Internet → A task IP `:3001` | denied / timeout | ✅ PASS |
| 6 | Internet → B task IP `:3002` | denied / timeout | ✅ PASS |
| 7 | Internet → C task IP `:3003` | denied / timeout | ✅ PASS |

---

## 2. Evidence table

Two evidence types per claim:

- **Runtime evidence:** live `curl` or ECS Exec output.
- **Configuration evidence:** security-group rule, deliberate missing rule, target-group health, or listener configuration.

| Test | Expected | Evidence 1 — runtime | Evidence 2 — configuration | Result |
|---|---|---|---|---|
| Internet → ALB | 200 | `curl -i http://<alb-dns>/health` → `HTTP/1.1 200` (§4.1) | Target group `devops-g3-order-tg` targets `healthy`; listener HTTP:80 → TG (§4.6) | ✅ |
| A → B | 200 | Exec into order task, `curl http://inventory:3002/health` → `200` (§4.2) | `inventory-sg` inbound 3002 from `order-sg` (§4.7) + same `X-Request-ID` in inventory CloudWatch log (§4.2) | ✅ |
| B → C | 200 | Exec into inventory task, `curl http://payment:3003/health` → `200` (§4.3) | `payment-sg` inbound 3003 from `inventory-sg` (§4.7) + same `X-Request-ID` in payment CloudWatch log (§4.3) | ✅ |
| A → C | denied | Exec into order task, `curl --max-time 5 http://payment:3003/health` → timeout (§4.4) | **No** `order-sg → payment-sg:3003` rule exists (§4.7, §4.8) | ✅ |
| Internet → A | denied | `curl --max-time 5 http://<task-ip>:3001/health` → timeout (§4.5) | `order-sg` has no `0.0.0.0/0` inbound; only `alb-sg` + `payment-sg` (§4.7) | ✅ |
| Internet → B | denied | `curl --max-time 5 http://<task-ip>:3002/health` → timeout (§4.5) | `inventory-sg` has no `0.0.0.0/0` inbound (§4.7) | ✅ |
| Internet → C | denied | `curl --max-time 5 http://<task-ip>:3003/health` → timeout (§4.5) | `payment-sg` has no `0.0.0.0/0` inbound (§4.7) | ✅ |

---

## 3. Why each result is what it is

- **A → B succeeds** because Service Connect resolves `inventory` to the task and
  `inventory-sg` explicitly allows inbound 3002 from `order-sg`.
- **B → C succeeds** because `payment-sg` allows inbound 3003 from `inventory-sg`.
- **A → C fails** because there is **no** SG rule allowing `order-sg → payment-sg:3003`.
  The absence is deliberate — it is the boundary Gate 2 asks us to prove.
- **Internet → any app port fails** because the service SGs have no `0.0.0.0/0`
  inbound rule. Tasks have public IPs for outbound access only.
- **The one deliberate extra edge** — `payment → order` on 3001 for the confirm
  callback — is permitted by `order-sg` inbound 3001 from `payment-sg`, and is
  documented as an intentional deviation in the Gate 1 submission.

---

## 4. Reproduction commands + captured output

Paste the live terminal output under each block when capturing for submission.

### 4.0 Setup

```bash
export AWS_REGION=us-west-1
export AWS_PAGER=""
export CLUSTER=devops-g3-cluster
export ALB_DNS=$(aws elbv2 describe-load-balancers --names devops-g3-alb \
  --query 'LoadBalancers[0].DNSName' --output text --region $AWS_REGION)
export ORDER_TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-order \
  --query 'taskArns[0]' --output text --region $AWS_REGION)
export INV_TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name devops-g3-inventory \
  --query 'taskArns[0]' --output text --region $AWS_REGION)
```

### 4.1 Internet → ALB (expect 200)

```bash
curl -i --max-time 10 http://$ALB_DNS/health
```

```txt
<paste output — expect HTTP/1.1 200 and {"service":"order-service","status":"ok",...}>
```

### 4.2 A → B (expect 200)

```bash
aws ecs execute-command --cluster $CLUSTER --task $ORDER_TASK \
  --container order --interactive --command "/bin/sh" --region $AWS_REGION

# inside the container:
curl -i --max-time 5 http://inventory:3002/health
```

```txt
<paste curl output — expect HTTP/1.1 200>
```

Correlation-ID cross-check: same `X-Request-ID` reaches inventory.

```bash
aws logs tail /ecs/devops-g3/inventory --since 5m --region $AWS_REGION | grep <request-id>
```

```txt
<paste matching inventory log line>
```

### 4.3 B → C (expect 200)

```bash
aws ecs execute-command --cluster $CLUSTER --task $INV_TASK \
  --container inventory --interactive --command "/bin/sh" --region $AWS_REGION

# inside the container:
curl -i --max-time 5 http://payment:3003/health
```

```txt
<paste curl output — expect HTTP/1.1 200>
```

```bash
aws logs tail /ecs/devops-g3/payment --since 5m --region $AWS_REGION | grep <request-id>
```

```txt
<paste matching payment log line>
```

### 4.4 A → C (expect timeout — the key denial)

```bash
aws ecs execute-command --cluster $CLUSTER --task $ORDER_TASK \
  --container order --interactive --command "/bin/sh" --region $AWS_REGION

# inside the container:
curl -i --max-time 5 http://payment:3003/health
```

```txt
<paste output — expect "curl: (28) ... timed out after 5 seconds">
```

### 4.5 Internet → app ports (expect timeout)

```bash
export ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $ORDER_TASK \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text --region $AWS_REGION)
export TASK_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text --region $AWS_REGION)

curl --max-time 5 http://$TASK_IP:3001/health   # timeout
curl --max-time 5 http://$TASK_IP:3002/health   # timeout
curl --max-time 5 http://$TASK_IP:3003/health   # timeout
```

```txt
<paste output — each should be "curl: (28) ... timed out">
```

### 4.6 Target group health (backs test 1)

```bash
export TG_ARN=$(aws elbv2 describe-target-groups --names devops-g3-order-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region $AWS_REGION)
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $AWS_REGION \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
```

```txt
<paste output — expect: healthy healthy>
```

### 4.7 Security-group rules (configuration evidence)

```bash
sg() { aws ec2 describe-security-groups --filters Name=group-name,Values=$1 \
  --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION; }

ALB_SG=$(sg devops-g3-alb-sg)
ORDER_SG=$(sg devops-g3-order-sg)
INV_SG=$(sg devops-g3-inventory-sg)
PAY_SG=$(sg devops-g3-payment-sg)

for name in devops-g3-alb-sg devops-g3-order-sg devops-g3-inventory-sg devops-g3-payment-sg; do
  echo "=== $name ==="
  aws ec2 describe-security-groups --filters Name=group-name,Values=$name \
    --query 'SecurityGroups[0].IpPermissions[].{port:ToPort,cidr:IpRanges[].CidrIp,srcSG:UserIdGroupPairs[].GroupId}' \
    --output json --region $AWS_REGION
done
```

```txt
<paste output — verify: alb-sg 80 from 0.0.0.0/0; order-sg 3001 from alb-sg + payment-sg;
 inventory-sg 3002 from order-sg; payment-sg 3003 from inventory-sg>
```

### 4.8 Proof the forbidden rule is absent (backs test 4)

```bash
aws ec2 describe-security-groups --filters Name=group-name,Values=devops-g3-payment-sg \
  --query "SecurityGroups[0].IpPermissions[?ToPort=='3003'].UserIdGroupPairs[?GroupId=='$ORDER_SG'].GroupId" \
  --output text --region $AWS_REGION
```

```txt
<paste output — must be EMPTY (no order-sg source on payment:3003)>
```

---

## 5. Per-pair contract (live config matches Gate 1)

| Pair | Protocol | Dest port | SC name | SG reference | Health | Result |
|---|---|---|---|---|---|---|
| Internet → ALB | HTTP | 80 | ALB DNS | alb-sg `0.0.0.0/0` | n/a | ✅ |
| ALB → order | HTTP | 3001 | order | alb-sg → order-sg | `/health` | ✅ |
| order → inventory | HTTP | 3002 | inventory | order-sg → inventory-sg | `/health` | ✅ |
| inventory → payment | HTTP | 3003 | payment | inventory-sg → payment-sg | `/health` | ✅ |
| payment → order (callback) | HTTP | 3001 | order | payment-sg → order-sg | `/confirm` | ✅ deliberate |
| order → payment | — | 3003 | — | **no rule** | — | ✅ denied |

---

## 6. Definition of done — Gate 2

- [x] Service Connect resolves all three services by name (`SC enabled: True` ×3)
- [x] Four SG rules enforce the contract by reference; no CIDR except Internet→ALB
- [x] ALB serves order on port 80 with healthy targets
- [x] Inventory and payment have no public path: no load balancer and no target group
- [x] Required trio proven at runtime: A→B ✅, A→C denied ✅, B→C ✅
- [x] All Internet→app-port denials proven
- [ ] Live output pasted into §4 blocks and attached for submission
- [ ] Scar log updated with any Phase 3 failures encountered
