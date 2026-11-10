#!/usr/bin/env bash
#
# start.sh
#
# Starts a previously stopped tools cluster and the registry.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

if ! host_exists; then
  echo "ERROR: k3d cluster '${HOST_CLUSTER}' does not exist. Run 'make run' first." >&2
  exit 1
fi

log "Starting registry…"
docker start "${REG_NAME}" >/dev/null

log "Starting k3d cluster '${HOST_CLUSTER}'…"
k3d cluster start "${HOST_CLUSTER}"

log "Waiting for the tools cluster API…"
for _ in $(seq 1 60); do
  if kubectl --context "${HOST_CONTEXT}" cluster-info &>/dev/null; then
    break
  fi
  sleep 2
done

log "Host started."
"${SCRIPT_DIR}/status.sh"
