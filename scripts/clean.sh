#!/usr/bin/env bash
#
# clean.sh
#
# Tears down the entire IDP local environment using Terraform.
#
# Usage:
#   ./scripts/clean.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

TF_DIR="${REPO_ROOT}/terraform"

# ---------- Destroy Gitea repositories (best effort) -------------------------
if [[ -f "${TF_DIR}/repositories/terraform.tfstate" ]]; then
  log "Destroying Gitea repositories…"
  if resolve_gitea; then
    GITEA_LOCAL_PORT=3000
    kubectl --context "${HUB_CONTEXT}" -n gitea port-forward svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &
    PORTFWD_PID=$!
    sleep 2
    [[ -d "${TF_DIR}/repositories/.terraform" ]] || terraform -chdir="${TF_DIR}/repositories" init -input=false
    terraform -chdir="${TF_DIR}/repositories" destroy -auto-approve -input=false \
      -var "gitea_url=http://localhost:${GITEA_LOCAL_PORT}" \
      -var "gitea_username=${GITEA_ADMIN_USER}" \
      -var "gitea_password=${GITEA_ADMIN_PASS}" || true
    kill "${PORTFWD_PID}" 2>/dev/null || true
  fi
fi

# ---------- Destroy clusters + registry via Terraform -------------------------
if [[ -f "${TF_DIR}/clusters/terraform.tfstate" ]]; then
  log "Destroying clusters and registry…"
  [[ -d "${TF_DIR}/clusters/.terraform" ]] || terraform -chdir="${TF_DIR}/clusters" init -input=false
  terraform -chdir="${TF_DIR}/clusters" destroy -auto-approve -input=false
fi

log "Teardown complete."
