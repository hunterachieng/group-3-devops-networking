#!/usr/bin/env bash
#
# wait-for-deps.sh
#
# Used by order.service as an ExecStartPre gate. It blocks until BOTH
# Inventory and Payment answer their /health endpoints, which is how we
# enforce the assignment requirement:
#
#   "Service A does not become operational until its dependencies are available."
#
# systemd's After= only guarantees the dependency PROCESSES were launched,
# not that they are actually listening yet. This script closes that gap.
#
# Exit 0 = all dependencies are healthy, Order may start.
# Exit 1 = timed out waiting; Order will fail to start (visible in journalctl).

set -u

DEPS=(
  "http://inventory.internal:3002/health"
  "http://payment.internal:3003/health"
)

TIMEOUT="${DEPS_TIMEOUT:-60}"          # seconds to wait before giving up
deadline=$(( $(date +%s) + TIMEOUT ))

for url in "${DEPS[@]}"; do
  until curl -fsS --max-time 2 "$url" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "wait-for-deps: TIMED OUT waiting for $url" >&2
      exit 1
    fi
    echo "wait-for-deps: waiting for $url ..." >&2
    sleep 1
  done
  echo "wait-for-deps: $url is healthy" >&2
done

echo "wait-for-deps: all dependencies ready, starting Order" >&2
exit 0
