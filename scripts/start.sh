#!/usr/bin/env bash
#
# start.sh
#
# Starts previously stopped Kind cluster containers and the registry.
# Use after `stop.sh` to resume the platform without re-bootstrapping.
#
# Usage:
#   ./scripts/start.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

log "Starting registry container…"
if docker ps -a -q -f "name=^${REG_NAME}$" | grep -q .; then
  docker start "${REG_NAME}"
  log "  Started ${REG_NAME}"
else
  log "  ${REG_NAME} container not found — run 'make run' first"
  exit 1
fi

log "Starting Kind cluster containers…"
for c in "${CLUSTERS[@]}"; do
  container="${c}-control-plane"
  if docker ps -a -q -f "name=^${container}$" | grep -q .; then
    docker start "${container}"
    log "  Started ${container}"
  else
    log "  ${container} container not found (skipped)"
  fi
done

# Wait for API servers to become reachable
log "Waiting for clusters to become ready…"
for c in "${CLUSTERS[@]}"; do
  container="${c}-control-plane"
  docker ps -q -f "name=^${container}$" | grep -q . || continue
  log "  Waiting for kind-${c}…"
  for i in $(seq 1 60); do
    if kubectl --context "kind-${c}" cluster-info &>/dev/null; then
      log "  kind-${c} is ready"
      break
    fi
    sleep 2
  done
done

log "All containers started."
"${SCRIPT_DIR}/status.sh"
