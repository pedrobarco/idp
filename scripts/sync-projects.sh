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

# Build the Gitea remote URL for a given repo name.
gitea_remote_url() {
  echo "http://${GITEA_AUTH}@${GITEA_URL#http://}/${GITEA_ADMIN_USER}/${1}.git"
}

# Sync the IDP repo to Gitea. Local workspace is the source of truth;
# any remote-only changes (e.g. from Kargo) are overwritten.
push_idp() {
  local remote
  remote=$(gitea_remote_url "idp")
  local tmp
  tmp=$(mktemp -d)

  if git clone -q --single-branch --branch main "${remote}" "${tmp}" 2>/dev/null; then
    : # cloned
  else
    git -C "${tmp}" init -q
    git -C "${tmp}" checkout -q -b main
    git -C "${tmp}" remote add origin "${remote}"
  fi

  rsync -a --delete --exclude='.git' --exclude='charts/' --exclude='node_modules/' \
    "${REPO_ROOT}/" "${tmp}/"
  git -C "${tmp}" add -A

  if git -C "${tmp}" diff --cached --quiet; then
    echo "  (no changes)"
  else
    git -C "${tmp}" -c user.name="idp" -c user.email="idp@local" \
      commit -q -m "sync: update idp"
    git -C "${tmp}" push --force -u origin main 2>&1 || \
      echo "  WARNING: push failed for idp"
  fi

  rm -rf "${tmp}"
}

# Sync a project subdirectory to its own Gitea repo using git subtree.
# Extracts commits that touch projects/<name>/ and force-pushes them,
# preserving the original commit messages and history.
push_project() {
  local name="$1"
  local prefix="projects/${name}"
  local remote
  remote=$(gitea_remote_url "${name}")
  local remote_name="gitea-${name}"

  # Ensure remote exists with correct URL
  if git -C "${REPO_ROOT}" remote get-url "${remote_name}" &>/dev/null; then
    git -C "${REPO_ROOT}" remote set-url "${remote_name}" "${remote}"
  else
    git -C "${REPO_ROOT}" remote add "${remote_name}" "${remote}"
  fi

  local split_ref
  split_ref=$(git -C "${REPO_ROOT}" subtree split --prefix="${prefix}" 2>/dev/null | tail -1)
  git -C "${REPO_ROOT}" push --force "${remote_name}" "${split_ref}:refs/heads/main" 2>&1 || \
    echo "  WARNING: push failed for ${name}"

  git -C "${REPO_ROOT}" remote remove "${remote_name}" 2>/dev/null || true
}

# ── Sync all repos ──────────────────────────────────────────────────────────
log "Syncing idp…"
push_idp
log "idp ✓"
echo

for project_path in "${PROJECTS_DIR}"/*/; do
  [[ -d "${project_path}" ]] || continue
  project="$(basename "${project_path}")"
  log "Syncing ${project}…"
  push_project "${project}"
  log "${project} ✓"
  echo
done

log "All repos synced."
