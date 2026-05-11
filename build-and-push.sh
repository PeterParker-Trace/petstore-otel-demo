#!/usr/bin/env bash
# build-and-push.sh — Build all 5 service images for ARM64 and push to ECR.
#
# Prerequisites (one-time):
#   - terraform/persistent stack applied (ECR repos exist)
#   - aws ecr get-login-password ... | docker login ...   (within last 12 hours)
#
# Usage (run from repo root):
#   ./build-and-push.sh
#
# Or to push only one service:
#   ./build-and-push.sh frontend

set -euo pipefail
# set -e  → exit immediately if any command fails (don't push 4 broken images then fail on the 5th)
# set -u  → fail on unset variables (catches typos)
# set -o pipefail → fail if any command in a pipeline fails (default only checks the last one)

# Determine where this script lives so it works regardless of working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# All 5 services we need to build.
ALL_SERVICES=("frontend" "api-gateway" "catalog-service" "orders-service" "payments-service")

# If a specific service was passed as an argument, only build that one.
if [[ $# -gt 0 ]]; then
  SERVICES=("$@")
else
  SERVICES=("${ALL_SERVICES[@]}")
fi

# Validate each requested service is real.
for SVC in "${SERVICES[@]}"; do
  if [[ ! " ${ALL_SERVICES[*]} " =~ " ${SVC} " ]]; then
    echo "ERROR: unknown service '$SVC'. Valid: ${ALL_SERVICES[*]}"
    exit 1
  fi
done

echo "============================================================"
echo "Build & push plan"
echo "============================================================"
echo "Services: ${SERVICES[*]}"
echo "Target architecture: linux/arm64 (for Graviton EC2)"
echo ""

# Pull the ECR registry hostname from Terraform outputs.
# This means the script works for any AWS account; nothing's hardcoded.
echo "Reading ECR URLs from terraform/persistent..."
cd terraform/persistent
ECR_REGISTRY=$(terraform output -raw ecr_registry_url)
# Get the full map of service -> URL once, parse it for each service.
ECR_URLS_JSON=$(terraform output -json ecr_repository_urls)
cd "$SCRIPT_DIR"
echo "Registry: $ECR_REGISTRY"
echo ""

# Helper: extract a single repo URL from the JSON map.
get_ecr_url() {
  local svc="$1"
  echo "$ECR_URLS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['$svc'])"
}

# Ensure docker buildx is set up. The default 'docker' builder doesn't support
# --platform cross-builds. The 'docker-container' driver does.
echo "Ensuring buildx builder is ready..."
docker buildx inspect petstore-builder >/dev/null 2>&1 || \
  docker buildx create --name petstore-builder --driver docker-container --use
docker buildx use petstore-builder >/dev/null
echo ""

# Build and push each service.
for SVC in "${SERVICES[@]}"; do
  ECR_URL=$(get_ecr_url "$SVC")
  echo "============================================================"
  echo "[$SVC]"
  echo "  Source: services/$SVC"
  echo "  Target: $ECR_URL:latest"
  echo "============================================================"

  # The actual build + push in one operation.
  #   --platform linux/arm64  → image is for ARM64 only (Graviton-compatible)
  #   --provenance=false      → suppresses extra attestation manifest some clients (and old ECS) dislike
  #   --push                  → push to registry instead of loading into local docker daemon
  docker buildx build \
    --platform linux/arm64 \
    --provenance=false \
    -t "$ECR_URL:latest" \
    --push \
    "services/$SVC"

  echo ""
  echo "✓ $SVC pushed."
  echo ""
done

# Summary: list what's in each repo so you can verify.
echo "============================================================"
echo "Verifying images in ECR..."
echo "============================================================"
for SVC in "${SERVICES[@]}"; do
  REPO_NAME="petstore-otel-demo/$SVC"
  TAG_INFO=$(aws ecr describe-images \
    --repository-name "$REPO_NAME" \
    --region eu-north-1 \
    --query 'imageDetails[?contains(imageTags, `latest`)].[imageTags[0], imagePushedAt, imageSizeInBytes]' \
    --output text 2>/dev/null || echo "(failed to query)")
  printf "  %-20s %s\n" "$SVC" "$TAG_INFO"
done

echo ""
echo "All done!"
