#!/usr/bin/env bash
#
# utils.sh
#
# Shared configuration and utility functions sourced by all IDP scripts.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------- Clusters ----------------------------------------------------------
CLUSTERS=(dev staging prod-1 prod-2)
HUB_CLUSTER="dev"
HUB_CONTEXT="kind-${HUB_CLUSTER}"

# ---------- Registry ----------------------------------------------------------
REG_NAME="kind-registry"
REG_PORT="5001"
REG_INTERNAL_PORT="5000"
REG_HOST="localhost:${REG_PORT}"

# ---------- Logging -----------------------------------------------------------
log() { echo "==> $*"; }

# ---------- Cluster helpers ---------------------------------------------------
cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$1"
}

wait_for_rollout() {
  local ctx="$1" ns="$2" deploy="$3"
  log "Waiting for ${deploy} in ${ns}…"
  kubectl --context "${ctx}" -n "${ns}" rollout status "deployment/${deploy}" --timeout=300s
}

# ---------- Credential helpers (read from cluster on demand) ------------------
# Reads an env var from the configure-gitea init container.
_gitea_init_env() {
  kubectl --context "${HUB_CONTEXT}" -n gitea \
    get deployment gitea \
    -o jsonpath="{.spec.template.spec.initContainers[?(@.name==\"configure-gitea\")].env[?(@.name==\"$1\")].value}" 2>/dev/null
}

gitea_admin_user() { _gitea_init_env GITEA_ADMIN_USERNAME; }
gitea_admin_pass() { _gitea_init_env GITEA_ADMIN_PASSWORD; }

gitea_domain() {
  kubectl --context "${HUB_CONTEXT}" -n gitea \
    get ingress gitea -o jsonpath='{.spec.rules[0].host}' 2>/dev/null
}

argocd_admin_pass() {
  kubectl --context "${HUB_CONTEXT}" -n argocd \
    get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null
}

# Lazily resolve Gitea config. Call this in scripts that need GITEA_* vars.
resolve_gitea() {
  [[ -n "${GITEA_ADMIN_USER:-}" ]] && return 0
  if ! kubectl --context "${HUB_CONTEXT}" -n gitea get deployment gitea &>/dev/null; then
    return 1
  fi
  GITEA_ADMIN_USER="$(gitea_admin_user)"
  GITEA_ADMIN_PASS="$(gitea_admin_pass)"
  GITEA_DOMAIN="$(gitea_domain)"
  GITEA_URL="http://${GITEA_DOMAIN}"
  GITEA_AUTH="${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}"
}
