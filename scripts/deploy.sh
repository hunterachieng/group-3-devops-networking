#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy.sh — pull and start the production stack from a pinned image tag.
#
# Usage:
#   export DOCKERHUB_USERNAME=<your-dockerhub-username>
#   ./scripts/deploy.sh sha-<short-commit-hash>
#
# Example:
#   ./scripts/deploy.sh sha-a1b2c3d
# ---------------------------------------------------------------------------

IMAGE_TAG="${1:-}"

if [ -z "$IMAGE_TAG" ]; then
  echo "ERROR: image tag is required."
  echo "Usage:   ./scripts/deploy.sh sha-<short-commit-hash>"
  echo "Example: ./scripts/deploy.sh sha-a1b2c3d"
  exit 1
fi

# Guard against accidentally deploying a mutable tag.
if [[ "$IMAGE_TAG" != sha-* ]]; then
  echo "ERROR: image tag must start with 'sha-' (got: $IMAGE_TAG)."
  echo "Never deploy using :latest, :main, or branch tags."
  exit 1
fi

if [ -z "${DOCKERHUB_USERNAME:-}" ]; then
  echo "ERROR: DOCKERHUB_USERNAME is not set."
  echo "Run: export DOCKERHUB_USERNAME=<your-dockerhub-username>"
  exit 1
fi

export IMAGE_TAG
export APP_NAME="${APP_NAME:-$(basename "$PWD")}"

echo "-----------------------------------------------"
echo "  Deploying: ${APP_NAME}"
echo "  Image tag: ${IMAGE_TAG}"
echo "  Hub user:  ${DOCKERHUB_USERNAME}"
echo "-----------------------------------------------"

echo ""
echo "Pulling images..."
docker compose -f docker-compose.prod.yml pull

echo ""
echo "Starting stack..."
docker compose -f docker-compose.prod.yml up -d --remove-orphans

echo ""
echo "Stack status:"
docker compose -f docker-compose.prod.yml ps
