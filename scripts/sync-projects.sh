#!/usr/bin/env bash
#
# sync-projects.sh
#
# Publishes folders from this repo to Gitea. This repo stays a GitHub
# history: the script never commits, merges, or adds remotes here.
#
#   gitops/            → gitops
#   actions/           → actions
#   projects/<name>/   → <name>
#
# Each Gitea repo is cloned under .sync/ (gitignored). The folder contents
# are committed on top of Gitea main and pushed. If that push is not a
# fast-forward, the script rebases and rewrites the Gitea branch.
#
# Usage:
#   ./scripts/sync-projects.sh
#
# Prerequisites: git, rsync
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Build the Gitea remote URL for a given repo name.
gitea_remote_url() {
  echo "http://${GITEA_AUTH}@${GITEA_URL#http://}/${GITEA_ADMIN_USER}/${1}.git"
}

# Clone or update the Gitea checkout for one folder, then publish it.
sync_prefix() {
  local prefix="$1"
  local name="$2"
  local remote work parent_head
  remote=$(gitea_remote_url "${name}")
  work="${REPO_ROOT}/.sync/${name}"

  if [[ ! -d "${REPO_ROOT}/${prefix}" ]]; then
    echo "ERROR: missing ${prefix}" >&2
    return 1
  fi

  parent_head=$(git -C "${REPO_ROOT}" rev-parse HEAD)
  mkdir -p "${REPO_ROOT}/.sync"

  if [[ ! -d "${work}/.git" ]]; then
    rm -rf "${work}"
    if git ls-remote --exit-code --heads "${remote}" main &>/dev/null; then
      git clone -q --branch main "${remote}" "${work}"
    else
      mkdir -p "${work}"
      git -C "${work}" init -q -b main
      git -C "${work}" remote add origin "${remote}"
    fi
  else
    git -C "${work}" remote set-url origin "${remote}"
    git -C "${work}" fetch -q origin main || true
    if git -C "${work}" rev-parse --verify --quiet origin/main >/dev/null; then
      git -C "${work}" checkout -q -B main origin/main
    else
      git -C "${work}" checkout -q -B main
    fi
  fi

  rsync -a --delete --exclude '.git/' "${REPO_ROOT}/${prefix}/" "${work}/"
  git -C "${work}" add -A
  if ! git -C "${work}" diff --cached --quiet; then
    git -C "${work}" \
      -c user.name="idp" -c user.email="idp@local" \
      commit -q -m "sync: update ${name} from ${parent_head}"
  fi

  if git -C "${work}" push -q origin HEAD:main; then
    return 0
  fi

  # Gitea moved, or the local checkout diverged. Rebase onto it and rewrite.
  git -C "${work}" fetch -q origin main
  if git -C "${work}" rev-parse --verify --quiet origin/main >/dev/null; then
    git -C "${work}" rebase -q origin/main
  fi
  git -C "${work}" push -q --force-with-lease origin HEAD:main
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
