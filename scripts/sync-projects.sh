#!/usr/bin/env bash
#
# sync-projects.sh
#
# Publishes each managed folder in this repo to its own Gitea repository.
#   gitops/            → gitops
#   actions/           → actions
#   projects/<name>/   → <name>
#
# For every folder: pull commits that exist only on Gitea (for example a
# Kargo promotion), then push the folder. The first push seeds an empty repo.
#
# Repos are created by Terraform (terraform/repositories). This script only
# moves git history.
#
# Usage:
#   ./scripts/sync-projects.sh
#
# Configuration is loaded from scripts/utils.sh
#
# Prerequisites: git (with git-subtree)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Build the Gitea remote URL for a given repo name.
gitea_remote_url() {
  echo "http://${GITEA_AUTH}@${GITEA_URL#http://}/${GITEA_ADMIN_USER}/${1}.git"
}

# Merge a subtree commit into prefix and record the join for the next split.
join_split() {
  local prefix="$1"
  local name="$2"
  local split_sha="$3"
  local verb="$4"
  local head_sha
  head_sha=$(git -C "${REPO_ROOT}" rev-parse HEAD)
  git -C "${REPO_ROOT}" \
    -c user.name="idp" -c user.email="idp@local" \
    merge --no-ff --allow-unrelated-histories -Xsubtree="${prefix}" \
    -m "$(printf 'sync: %s %s\n\ngit-subtree-dir: %s\ngit-subtree-mainline: %s\ngit-subtree-split: %s\n' \
      "${verb}" "${name}" "${prefix}" "${head_sha}" "${split_sha}")" \
    "${split_sha}"
}

# Pull Gitea main into prefix when the remote branch exists, then push prefix.
# Remote names are temporary and removed before returning.
sync_prefix() {
  local prefix="$1"
  local name="$2"
  local remote remote_name split_sha
  remote=$(gitea_remote_url "${name}")
  remote_name="gitea-${name}"

  if [[ ! -d "${REPO_ROOT}/${prefix}" ]]; then
    echo "ERROR: missing ${prefix}" >&2
    return 1
  fi

  if git -C "${REPO_ROOT}" remote get-url "${remote_name}" &>/dev/null; then
    git -C "${REPO_ROOT}" remote set-url "${remote_name}" "${remote}"
  else
    git -C "${REPO_ROOT}" remote add "${remote_name}" "${remote}"
  fi

  # The published folder history has no common ancestor with this repo until it
  # is joined back. Record that join so the next sync does not replay it.
  if git -C "${REPO_ROOT}" ls-remote --exit-code --heads "${remote_name}" main &>/dev/null; then
    git -C "${REPO_ROOT}" fetch --quiet "${remote_name}" main
    if ! git -C "${REPO_ROOT}" merge-base --is-ancestor FETCH_HEAD HEAD; then
      join_split "${prefix}" "${name}" "$(git -C "${REPO_ROOT}" rev-parse FETCH_HEAD)" "pull"
    fi
  fi

  split_sha=$(git -C "${REPO_ROOT}" subtree split --prefix="${prefix}")
  git -C "${REPO_ROOT}" push "${remote_name}" "${split_sha}:refs/heads/main"
  if ! git -C "${REPO_ROOT}" merge-base --is-ancestor "${split_sha}" HEAD; then
    join_split "${prefix}" "${name}" "${split_sha}" "record"
  fi
  git -C "${REPO_ROOT}" remote remove "${remote_name}"
}

sync_all() {
  local project_path project

  log "Syncing gitops…"
  sync_prefix "gitops" "gitops"
  log "gitops ✓"
  echo

  log "Syncing actions…"
  sync_prefix "actions" "actions"
  log "actions ✓"
  echo

  for project_path in "${REPO_ROOT}/projects"/*/; do
    [[ -d "${project_path}" ]] || continue
    project="$(basename "${project_path}")"
    log "Syncing ${project}…"
    sync_prefix "projects/${project}" "${project}"
    log "${project} ✓"
    echo
  done

  log "All repos synced."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  resolve_gitea || { echo "ERROR: Gitea is not running." >&2; exit 1; }
  sync_all
fi
