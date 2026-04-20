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
    [[ -d "${TF_DIR}/repositories/.terraform" ]] || terraform -chdir="${TF_DIR}/repositories" init -input=false
    terraform -chdir="${TF_DIR}/repositories" destroy -auto-approve -input=false \
      -var "gitea_url=${GITEA_URL}" \
      -var "gitea_username=${GITEA_ADMIN_USER}" \
      -var "gitea_password=${GITEA_ADMIN_PASS}" || true
  fi
fi

# ---------- Destroy clusters + registry via Terraform -------------------------
if [[ -f "${TF_DIR}/clusters/terraform.tfstate" ]]; then
  log "Destroying clusters and registry…"
  [[ -d "${TF_DIR}/clusters/.terraform" ]] || terraform -chdir="${TF_DIR}/clusters" init -input=false
  terraform -chdir="${TF_DIR}/clusters" destroy -auto-approve -input=false
fi

# ---------- Clean generated secret env files ----------------------------------
log "Removing generated secret env files…"
for dir in \
  "${REPO_ROOT}/bootstrap/dev/cluster-secrets/secrets" \
  "${REPO_ROOT}/infrastructure/gitea/secrets"; do
  [[ -d "${dir}" ]] && find "${dir}" -name '*.env' ! -name '*.env.example' -delete
done

log "Teardown complete."
