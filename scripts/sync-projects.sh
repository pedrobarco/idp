#!/usr/bin/env bash
#
# sync-projects.sh
#
# Syncs the IDP repository and local projects/*/ with Gitea.
#   1. Pushes the full IDP repo to Gitea (used by ArgoCD for GitOps)
#   2. Pushes each projects/*/ as a separate repo
#
# Note: Repos are created by Terraform (terraform/repositories).
# This script only pushes content.
#
# Usage:
#   ./scripts/sync-projects.sh
#
# Configuration is loaded from scripts/utils.sh
#
# Prerequisites: git, rsync
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"
resolve_gitea || { echo "ERROR: Gitea is not running." >&2; exit 1; }

PROJECTS_DIR="${REPO_ROOT}/projects"

push_dir() {
  local name="$1" src="$2"
  local remote="http://${GITEA_AUTH}@${GITEA_URL#http://}/${GITEA_ADMIN_USER}/${name}.git"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  rsync -a --exclude='.git' --exclude='charts/' --exclude='node_modules/' "${src}/" "${tmp_dir}/"
  git -C "${tmp_dir}" init -q
  git -C "${tmp_dir}" checkout -q -b main
  git -C "${tmp_dir}" add -A
  git -C "${tmp_dir}" -c user.name="idp" -c user.email="idp@local" \
    commit -q -m "Sync ${name}" --allow-empty
  git -C "${tmp_dir}" remote add origin "${remote}"
  git -C "${tmp_dir}" push -u origin main --force 2>&1 || \
    echo "  WARNING: push failed for ${name} — check Gitea connectivity."
  rm -rf "${tmp_dir}"
}

# ── 1. Sync the IDP repo (used by ArgoCD bootstrap + ApplicationSet) ────────
log "Syncing IDP repo…"
push_dir "idp" "${REPO_ROOT}"
log "idp ✓"
echo

# ── 2. Sync each project ────────────────────────────────────────────────────
for project_path in "${PROJECTS_DIR}"/*/; do
  [[ -d "${project_path}" ]] || continue
  project="$(basename "${project_path}")"
  log "Syncing ${project}…"
  push_dir "${project}" "${project_path}"
  log "${project} ✓"
  echo
done

log "All repos synced."
