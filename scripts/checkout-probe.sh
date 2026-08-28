#!/usr/bin/env bash
# Send repeated checkout requests for incident drills and SLI data generation.
set -euo pipefail

INTERVAL=10
COUNT=0
ALB_DNS=""

usage() {
  cat <<'EOF'
Usage: checkout-probe.sh [options]

Options:
  --alb DNS       ALB DNS name (default: terraform output alb_dns_name)
  --interval SEC  Seconds between requests (default: 10)
  --count N       Stop after N requests (default: unlimited)
  -h              Show this help

Examples:
  ./scripts/checkout-probe.sh
  ./scripts/checkout-probe.sh --interval 5 --count 20
  ./scripts/checkout-probe.sh --alb my-alb.us-west-1.elb.amazonaws.com
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alb)
      ALB_DNS="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --count)
      COUNT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ALB_DNS" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  ALB_DNS="$(terraform -chdir="${REPO_ROOT}/infra/environments/lab" output -raw alb_dns_name 2>/dev/null || true)"
fi

if [[ -z "$ALB_DNS" ]]; then
  AWS_REGION="${AWS_REGION:-us-west-1}"
  ALB_DNS="$(aws elbv2 describe-load-balancers --names devops-g3-iac-alb \
    --query 'LoadBalancers[0].DNSName' --output text --region "$AWS_REGION" 2>/dev/null || true)"
fi

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
  echo "ALB DNS not set. Pass --alb, run 'terraform init' in infra/environments/lab, or ensure AWS CLI can read devops-g3-iac-alb." >&2
  exit 1
fi

URL="http://${ALB_DNS}/checkout"
SENT=0

echo "Probing ${URL} every ${INTERVAL}s (Ctrl-C to stop)"

while true; do
  TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  HTTP_CODE="$(curl -s -o /tmp/checkout-probe-body.json -w "%{http_code}" \
    -X POST "$URL" \
    -H 'Content-Type: application/json' \
    -d '{"items":["BOOK-42"],"amount":3500}')"
  OUTCOME="$(python3 -c "import json; print(json.load(open('/tmp/checkout-probe-body.json')).get('outcome','?'))" 2>/dev/null || echo "?")"
  echo "${TS}  http=${HTTP_CODE}  outcome=${OUTCOME}"

  SENT=$((SENT + 1))
  if [[ "$COUNT" -gt 0 && "$SENT" -ge "$COUNT" ]]; then
    break
  fi
  sleep "$INTERVAL"
done
