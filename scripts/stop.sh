#!/usr/bin/env bash
#
# stop.sh
#
# Stops all Kind cluster containers and the registry without deleting them.
# State is preserved — use `start.sh` to resume.
#
# Usage:
#   ./scripts/stop.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

log "Stopping Kind cluster containers…"
for c in "${CLUSTERS[@]}"; do
  container="${c}-control-plane"
  if docker ps -q -f "name=^${container}$" | grep -q .; then
    docker stop "${container}"
    log "  Stopped ${container}"
  else
    log "  ${container} is not running (skipped)"
  fi
done

log "Stopping registry container…"
if docker ps -q -f "name=^${REG_NAME}$" | grep -q .; then
  docker stop "${REG_NAME}"
  log "  Stopped ${REG_NAME}"
else
  log "  ${REG_NAME} is not running (skipped)"
fi

log "All containers stopped. Run 'make start' to resume."
