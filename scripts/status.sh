#!/usr/bin/env bash
#
# status.sh — IDP platform status
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

COL="%-28s %-10s %s\n"
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }
row()     { printf "  ${COL}" "$1" "$2" "$3"; }

# helper: get host port for a cluster
cluster_port() {
  docker inspect "${1}-control-plane" \
    --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' 2>/dev/null || echo "?"
}

# helper: get ingress URL for a namespace/name on a cluster
ingress_url() {
  local ctx="$1" ns="$2" name="$3"
  local host port
  host=$(kubectl --context "${ctx}" -n "${ns}" get ingress "${name}" \
    -o jsonpath='{.spec.rules[0].host}' 2>/dev/null) || return
  [[ -z "${host}" ]] && return
  port=$(cluster_port "${ctx#kind-}")
  [[ "${port}" == "80" ]] && echo "http://${host}" || echo "http://${host}:${port}"
}

# ---------- Bootstrap --------------------------------------------------------
section "Bootstrap"

ARGOCD_PASS="$(argocd_admin_pass 2>/dev/null || echo '<unavailable>')"
ARGOCD_URL=$(ingress_url "${HUB_CONTEXT}" argocd argocd-server 2>/dev/null || echo '<unavailable>')
GITEA_USER="$(gitea_admin_user 2>/dev/null || echo '?')"
GITEA_PASS="$(gitea_admin_pass 2>/dev/null || echo '?')"
GITEA_INGRESS_URL=$(ingress_url "${HUB_CONTEXT}" gitea gitea 2>/dev/null || echo '<unavailable>')

row "argocd" "${ARGOCD_URL}" "(admin / ${ARGOCD_PASS})"
row "gitea"  "${GITEA_INGRESS_URL}" "(${GITEA_USER} / ${GITEA_PASS})"

# ---------- ApplicationSets -------------------------------------------------
section "ApplicationSets"

kubectl --context "${HUB_CONTEXT}" -n argocd get applicationsets \
  --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | while read -r appset; do
    printf "  \033[1m%s\033[0m\n" "${appset}"
    kubectl --context "${HUB_CONTEXT}" -n argocd get applications \
      -l "app.kubernetes.io/name=${appset}" --no-headers \
      -o custom-columns='NAME:.metadata.name,CLUSTER:.metadata.labels.app\.kubernetes\.io/cluster,NS:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status' \
      2>/dev/null | while read -r name cluster ns sync health; do
        url=$(ingress_url "kind-${cluster}" "${ns}" "${appset}" 2>/dev/null || true)
        row "${name}" "${sync}/${health}" "${url}"
      done
  done

echo ""
