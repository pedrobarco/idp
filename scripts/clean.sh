#!/usr/bin/env bash
#
# clean.sh
#
# Tears down the entire IDP local environment:
#   - Deletes all kind clusters
#   - Removes the local Docker registry
#   - Cleans up the Docker network
#
# Usage:
#   ./scripts/clean.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ---------- Delete kind clusters (parallel) ----------------------------------
PIDS=()
for c in "${CLUSTERS[@]}"; do
  if cluster_exists "${c}"; then
    log "Deleting cluster '${c}'…"
    kind delete cluster --name "${c}" &
    PIDS+=($!)
  else
    log "Cluster '${c}' does not exist — skipping."
  fi
done
for pid in "${PIDS[@]}"; do wait "${pid}"; done

# ---------- Remove local registry -------------------------------------------
if docker inspect "${REG_NAME}" &>/dev/null; then
  log "Removing registry '${REG_NAME}'…"
  docker rm -f "${REG_NAME}"
else
  log "Registry '${REG_NAME}' does not exist — skipping."
fi

# ---------- Clean up Docker network -----------------------------------------
if docker network inspect kind &>/dev/null; then
  log "Removing Docker network 'kind'…"
  docker network rm kind 2>/dev/null || true
fi

log "Teardown complete."
