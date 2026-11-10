#!/usr/bin/env bash
#
# clean.sh
#
# Tears down the tools cluster, its vclusters, and the local registry.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

TF_DIR="${REPO_ROOT}/terraform"

if [[ -f "${TF_DIR}/repositories/terraform.tfstate" ]]; then
  log "Destroying Gitea repositories…"
  if resolve_gitea; then
    [[ -d "${TF_DIR}/repositories/.terraform" ]] || terraform -chdir="${TF_DIR}/repositories" init -input=false
    terraform -chdir="${TF_DIR}/repositories" destroy -auto-approve -input=false \
      -var "gitea_url=${GITEA_URL}" \
      -var "gitea_username=${GITEA_ADMIN_USER}" \
      -var "gitea_password=${GITEA_ADMIN_PASS}" || true
  fi
fi

if host_exists; then
  log "Deleting k3d cluster '${HOST_CLUSTER}'…"
  k3d cluster delete "${HOST_CLUSTER}"
fi

if k3d registry list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${REG_NAME}"; then
  log "Deleting registry ${REG_NAME}…"
  k3d registry delete kind-registry
fi

log "Removing generated secret env files…"
gitea_secrets="${REPO_ROOT}/gitops/clusters/tools/gitea/gitea/secrets"
[[ -d "${gitea_secrets}" ]] && find "${gitea_secrets}" -name '*.env' ! -name '*.env.example' -delete
rm -rf "${REPO_ROOT}/.idp"

log "Teardown complete."
