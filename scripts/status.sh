#!/usr/bin/env bash
#
# status.sh — IDP platform status
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

section() { printf "\n\033[1m%s\033[0m\n" "$1"; }
subsection() { printf "  \033[1m%s\033[0m\n" "$1"; }

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
resolve_gitea || true

echo "  ArgoCD  ${ARGOCD_URL}  (admin / ${ARGOCD_PASS})"
echo "  Gitea   ${GITEA_URL:-<unavailable>}  (${GITEA_ADMIN_USER:-?} / ${GITEA_ADMIN_PASS:-?})"

# ---------- Infrastructure ---------------------------------------------------
section "Infrastructure"

INFRA_APPS=$(kubectl --context "${HUB_CONTEXT}" -n argocd get applicationsets \
  --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true)
FOUND_INFRA=false
for appset in ${INFRA_APPS}; do
  # infra appsets have no matching directory under apps/
  [[ -d "${REPO_ROOT}/apps/${appset}" ]] && continue
  FOUND_INFRA=true
  subsection "${appset}"
  kubectl --context "${HUB_CONTEXT}" -n argocd get applications \
    -l "app.kubernetes.io/name=${appset}" --no-headers \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    2>/dev/null | sed 's/^/    /' || true
done
${FOUND_INFRA} || echo "  none"

# ---------- Applications -----------------------------------------------------
section "Applications"

APP_SETS=$(kubectl --context "${HUB_CONTEXT}" -n argocd get applicationsets \
  --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true)
FOUND_APPS=false
for appset in ${APP_SETS}; do
  # app appsets have a matching directory under apps/
  [[ -d "${REPO_ROOT}/apps/${appset}" ]] || continue
  FOUND_APPS=true
  subsection "${appset}"
  for c in "${CLUSTERS[@]}"; do
    CTX="kind-${c}"
    DEPLOYS=$(kubectl --context "${CTX}" get deployments -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' \
      2>/dev/null | grep " ${appset} " || true)
    [[ -z "${DEPLOYS}" ]] && continue
    while IFS= read -r line; do
      ns=$(echo "${line}" | awk '{print $1}')
      ready=$(echo "${line}" | awk '{print $3}')
      desired=$(echo "${line}" | awk '{print $4}')
      url=$(ingress_url "${CTX}" "${ns}" "${appset}" 2>/dev/null || true)
      if [[ -n "${url}" ]]; then
        echo "    ${c}/${ns}  ${ready:-0}/${desired}  ${url}"
      else
        echo "    ${c}/${ns}  ${ready:-0}/${desired}"
      fi
    done <<< "${DEPLOYS}"
  done
done
${FOUND_APPS} || echo "  none"

# ---------- ArgoCD Status ----------------------------------------------------
section "ArgoCD"

kubectl --context "${HUB_CONTEXT}" -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  2>/dev/null || echo "  not available"

echo ""
