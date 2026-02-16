#!/usr/bin/env bash
set -euo pipefail

# Generic deploy helper for solo-stack projects.
# Usage: ./scripts/deploy.sh <project-dir> [service]
#
# Examples:
#   ./scripts/deploy.sh saas-app
#   ./scripts/deploy.sh saas-app app

PROJECT_DIR="${1:?Usage: deploy.sh <project-dir> [service]}"
SERVICE="${2:-}"
BASE_DIR="/opt/solo-stack"

cd "$BASE_DIR/$PROJECT_DIR"

if [ -n "$SERVICE" ]; then
    echo "Deploying service '$SERVICE' in $PROJECT_DIR..."
    docker compose pull "$SERVICE"
    docker compose up -d --no-deps "$SERVICE"
else
    echo "Deploying all services in $PROJECT_DIR..."
    docker compose pull
    docker compose up -d
fi

# Clean up dangling images
docker image prune -f

echo "Deploy complete: $PROJECT_DIR"
