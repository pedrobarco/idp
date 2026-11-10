#!/usr/bin/env bash
#
# stop.sh
#
# Stops the tools cluster and the registry without deleting them.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

if host_exists; then
  log "Stopping k3d cluster '${HOST_CLUSTER}'…"
  k3d cluster stop "${HOST_CLUSTER}"
else
  log "k3d cluster '${HOST_CLUSTER}' is not present"
fi

if docker ps -q -f "name=^${REG_NAME}$" | grep -q .; then
  log "Stopping registry…"
  docker stop "${REG_NAME}" >/dev/null
fi

log "Stopped. Run 'make start' to resume."
