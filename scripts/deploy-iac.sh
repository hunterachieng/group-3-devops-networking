#!/usr/bin/env bash
# deploy-iac.sh — deploy the latest built SHAs for all IaC services via Terraform.
#
# Usage:
#   ./scripts/deploy-order-iac.sh                          # all services from SSM
#   ./scripts/deploy-order-iac.sh order=abc1234            # override one SHA
#   ./scripts/deploy-order-iac.sh order=abc1234 inventory=def5678 payment=ghi9012
#
# Each service's SHA is published to SSM by its CodePipeline build automatically.
# Any SHA not supplied on the command line is read from SSM.
#
# Requirements: terraform >= 1.11, aws CLI, AWS creds with S3/ECS/ECR/SSM access.
#
# ── Credentials setup (run ONCE per terminal session before this script) ──────
#
# Terraform does NOT use the login_session plugin in ~/.aws/config.
# You must export real credentials into the shell first:
#
#   eval $(aws configure export-credentials --format env)
#   echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"   # confirm non-empty
#
# If export-credentials is unavailable (older CLI), copy the three export lines
# from your lab portal ("AWS CLI credentials" / "Session credentials") and paste:
#
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_SESSION_TOKEN=...
#
# Then verify before running:
#   aws sts get-caller-identity --region us-west-1   # must return your current account ID
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-west-1}"
INFRA_DIR="$(cd "$(dirname "$0")/../infra/environments/lab" && pwd)"
SERVICES=(order inventory payment)

# ── 1. Parse optional SHA overrides (key=value args) ─────────────────────────
declare -A OVERRIDE_SHA
for arg in "$@"; do
  svc="${arg%%=*}"
  sha="${arg#*=}"
  OVERRIDE_SHA[$svc]="$sha"
done

# ── 2. Resolve SHA for each service (override > SSM) ─────────────────────────
declare -A SHA
for svc in "${SERVICES[@]}"; do
  if [[ -n "${OVERRIDE_SHA[$svc]:-}" ]]; then
    SHA[$svc]="${OVERRIDE_SHA[$svc]}"
    echo "[$svc] using provided SHA: ${SHA[$svc]}"
  else
    param="/devops-g3-iac/$svc/image-tag"
    echo "[$svc] fetching SHA from SSM $param ..."
    SHA[$svc]=$(aws ssm get-parameter --name "$param" \
      --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    if [[ -z "${SHA[$svc]}" || "${SHA[$svc]}" == "REPLACE_ME" ]]; then
      echo "[$svc] WARNING: SSM parameter not found or REPLACE_ME — skipping ECR check, using REPLACE_ME"
      SHA[$svc]="REPLACE_ME"
    else
      echo "[$svc] SSM SHA: ${SHA[$svc]}"
    fi
  fi
done

# ── 3. Verify each non-placeholder SHA exists in ECR ─────────────────────────
echo ""
for svc in "${SERVICES[@]}"; do
  if [[ "${SHA[$svc]}" == "REPLACE_ME" ]]; then
    echo "[$svc] skipping ECR check (no SHA yet)"
    continue
  fi
  echo "[$svc] verifying devops-g3-iac-$svc:${SHA[$svc]} in ECR ..."
  aws ecr describe-images --repository-name "devops-g3-iac-$svc" \
    --image-ids imageTag="${SHA[$svc]}" --region "$AWS_REGION" \
    --query 'imageDetails[0].imageTags' --output text
  echo "[$svc] image confirmed."
done

# ── 4. Terraform init + plan ──────────────────────────────────────────────────
cd "$INFRA_DIR"
echo ""
echo "=== terraform init ==="
terraform init -input=false

echo ""
echo "=== terraform plan ==="
echo "  order     = ${SHA[order]}"
echo "  inventory = ${SHA[inventory]}"
echo "  payment   = ${SHA[payment]}"
echo ""
terraform plan \
  -var="order_image_tag=${SHA[order]}" \
  -var="inventory_image_tag=${SHA[inventory]}" \
  -var="payment_image_tag=${SHA[payment]}" \
  -out=lab.tfplan

# ── 5. Prompt before apply ────────────────────────────────────────────────────
echo ""
read -r -p "Review the plan above. Apply? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted. Plan saved to lab.tfplan if you want to re-apply manually."
  exit 0
fi

# ── 6. Apply ──────────────────────────────────────────────────────────────────
echo ""
echo "=== terraform apply ==="
terraform apply lab.tfplan

# ── 7. Smoke test ─────────────────────────────────────────────────────────────
echo ""
echo "=== smoke test ==="
ALB_URL=$(terraform output -raw alb_url 2>/dev/null || echo "")
if [[ -n "$ALB_URL" ]]; then
  echo "Curling $ALB_URL/health ..."
  curl -s "$ALB_URL/health" | python3 -m json.tool
  echo ""
  echo "Curling $ALB_URL/version ..."
  curl -s "$ALB_URL/version" | python3 -m json.tool
else
  echo "Could not read alb_url output — check terraform outputs manually."
fi

# ── 8. Clean plan (must show no changes) ─────────────────────────────────────
echo ""
echo "=== terraform plan (must be: No changes) ==="
terraform plan \
  -var="order_image_tag=${SHA[order]}" \
  -var="inventory_image_tag=${SHA[inventory]}" \
  -var="payment_image_tag=${SHA[payment]}" \
  -detailed-exitcode && echo "Clean — no changes." || true

echo ""
echo "Done. Deployed SHAs:"
for svc in "${SERVICES[@]}"; do echo "  $svc = ${SHA[$svc]}"; done
