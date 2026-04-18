#!/usr/bin/env bash
#
# Build and push the hello-app container image.
#
# Usage:
#   ./ci/build.sh                          # tags with git SHA7
#   ./ci/build.sh --tag v1.0.0             # custom tag
#   REGISTRY=ghcr.io/org ./ci/build.sh     # custom registry
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_NAME="hello-app"
REGISTRY="${REGISTRY:-localhost:5001}"
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|-t) TAG="$2"; shift 2 ;;
    *) echo "Usage: $0 [--tag <tag>]" >&2; exit 1 ;;
  esac
done

if [[ -z "${TAG}" ]]; then
  TAG="$(git -C "${PROJECT_DIR}" rev-parse --short=7 HEAD)"
fi

IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

echo "==> Building ${IMAGE}…"
docker build -t "${IMAGE}" "${PROJECT_DIR}"

echo "==> Pushing ${IMAGE}…"
docker push "${IMAGE}"

echo "==> ${IMAGE_NAME}:${TAG} ✓"
