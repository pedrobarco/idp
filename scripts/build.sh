#!/usr/bin/env bash
#
# Build and push a container image.
#
# Flags:
#   --registry, -r  Registry host (default: localhost:5001)
#   --repo           Image repository name (required)
#   --tag, -t        Image tag (default: git SHA7)
#   --context, -c    Build context path (default: .)
#
set -euo pipefail

REGISTRY="localhost:5001"
REPOSITORY=""
TAG=""
CONTEXT="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry|-r) REGISTRY="$2"; shift 2 ;;
    --repo)        REPOSITORY="$2"; shift 2 ;;
    --tag|-t)      TAG="$2"; shift 2 ;;
    --context|-c)  CONTEXT="$2"; shift 2 ;;
    *) echo "Usage: $0 --repo <name> [--registry <host>] [--tag <tag>] [--context <path>]" >&2; exit 1 ;;
  esac
done

if [[ -z "${REPOSITORY}" ]]; then
  echo "ERROR: --repo is required." >&2
  exit 1
fi

if [[ -z "${TAG}" ]]; then
  TAG="$(git -C "${CONTEXT}" rev-parse --short=7 HEAD)"
fi

IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"

echo "==> Building ${IMAGE}…"
docker build -t "${IMAGE}" "${CONTEXT}"

echo "==> Pushing ${IMAGE}…"
docker push "${IMAGE}"

echo "==> ${REPOSITORY}:${TAG} ✓"
