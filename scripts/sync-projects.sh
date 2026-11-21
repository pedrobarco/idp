#!/usr/bin/env bash
#
# sync-projects.sh
#
# Publishes folders from this repo to Forgejo. This repo stays a GitHub
# history: the script never commits, merges, or adds remotes here.
#
#   kubernetes/{argocd,kargo,<component>} → platform, under kubernetes/
#   actions/           → actions
#   projects/<name>/   → <name>
#
# Each Forgejo repo is cloned under .sync/ (gitignored). actions, projects, and
# platform replace their tree. platform is force-pushed with --force-with-lease
# when Forgejo moved during the sync. gitops is seeded once, when it has no
# main branch, from each module's envs/ and from hello-app's deploy/envs/.
# After that Kargo is the only writer.
#
# Usage:
#   ./scripts/sync-projects.sh
#
# Prerequisites: git, rsync, python3
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# Build the Forgejo remote URL for a given repo name.
forgejo_remote_url() {
  echo "http://${FORGEJO_AUTH}@${FORGEJO_URL#http://}/${FORGEJO_ADMIN_USER}/${1}.git"
}

# Fetch origin/main when that branch exists. An empty Forgejo repo has no
# main yet: ls-remote exits 2 and there is nothing to fetch. Any other
# failure, such as auth or a down server, stops the sync.
fetch_origin_main() {
  local work="$1"
  local status=0
  git -C "${work}" ls-remote --exit-code --heads origin main >/dev/null || status=$?
  if [[ "${status}" -eq 0 ]]; then
    git -C "${work}" fetch -q origin main
  elif [[ "${status}" -eq 2 ]]; then
    return 0
  else
    echo "ERROR: failed to read main from the Forgejo remote." >&2
    return 1
  fi
}

# Copy one local folder onto its Forgejo checkout, replacing the previous tree.
replace_tree() {
  local source="$1"
  local work="$2"
  rsync -a --delete --exclude '.git/' --exclude 'charts/' "${source}/" "${work}/"
  find "${work}" -type d -name charts -prune -exec rm -rf {} +
}

# Clone or update the Forgejo checkout for one folder, then publish it.
sync_prefix() {
  local prefix="$1"
  local name="$2"
  local remote work parent_head
  remote=$(forgejo_remote_url "${name}")
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
    fetch_origin_main "${work}"
    if git -C "${work}" rev-parse --verify --quiet origin/main >/dev/null; then
      git -C "${work}" checkout -q -B main origin/main
    else
      git -C "${work}" checkout -q -B main
    fi
  fi

  replace_tree "${REPO_ROOT}/${prefix}" "${work}"
  git -C "${work}" add -A
  if ! git -C "${work}" diff --cached --quiet; then
    git -C "${work}" \
      -c user.name="idp" -c user.email="idp@local" \
      commit -q -m "sync: update ${name} from ${parent_head}"
  fi

  if git -C "${work}" push -q origin HEAD:main; then
    return 0
  fi

  # Forgejo moved, or the local checkout diverged. Rebase onto it and rewrite.
  fetch_origin_main "${work}"
  if git -C "${work}" rev-parse --verify --quiet origin/main >/dev/null; then
    git -C "${work}" rebase -q origin/main
  fi
  git -C "${work}" push -q --force-with-lease origin HEAD:main
}

# Publish the control plane. Kargo does not write this repo, so the tree is replaced.
# Layout matches the platform repo: kubernetes/argocd and kubernetes/kargo.
sync_platform() {
  local remote work parent_head src
  remote=$(forgejo_remote_url platform)
  work="${REPO_ROOT}/.sync/platform"
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
    fetch_origin_main "${work}"
    if git -C "${work}" rev-parse --verify --quiet origin/main >/dev/null; then
      git -C "${work}" checkout -q -B main origin/main
    else
      git -C "${work}" checkout -q -B main
    fi
  fi

  find "${work}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  mkdir -p "${work}/kubernetes"
  for src in argocd kargo cert-manager forgejo forgejo-actions ingress-nginx registry; do
    excludes=(--exclude '.git/' --exclude 'charts/' --exclude 'runner-token.env')
    rsync -a --delete "${excludes[@]}" \
      "${REPO_ROOT}/kubernetes/${src}/" "${work}/kubernetes/${src}/"
  done
  find "${work}" -type d -name charts -prune -exec rm -rf {} +

  git -C "${work}" add -A
  if ! git -C "${work}" diff --cached --quiet; then
    git -C "${work}" \
      -c user.name="idp" -c user.email="idp@local" \
      commit -q -m "sync: update platform from ${parent_head}"
  fi

  if git -C "${work}" push -q origin HEAD:main; then
    return 0
  fi
  fetch_origin_main "${work}"
  if git -C "${work}" rev-parse --verify --quiet origin/main >/dev/null; then
    git -C "${work}" rebase -q origin/main
  fi
  git -C "${work}" push -q --force-with-lease origin HEAD:main
}

# Seed gitops from each module's envs/ and from hello-app's deploy/envs/
# when the Forgejo repo has no main. Each env kustomization points at
# ../../base so local builds work before Forgejo exists. The seed rewrites
# that line to the platform or hello-app repo and places the directory at
# the gitops path. A later sync leaves main alone, including image tags and
# any directory Kargo has rendered.
seed_gitops() {
  local remote work parent_head
  remote=$(forgejo_remote_url gitops)
  if git ls-remote --exit-code --heads "${remote}" main &>/dev/null; then
    log "gitops main already exists; leaving it for Kargo"
    return 0
  fi

  work="${REPO_ROOT}/.sync/gitops"
  parent_head=$(git -C "${REPO_ROOT}" rev-parse HEAD)
  mkdir -p "${REPO_ROOT}/.sync"
  rm -rf "${work}"
  mkdir -p "${work}"
  git -C "${work}" init -q -b main
  git -C "${work}" remote add origin "${remote}"

  python3 - "${work}" "${REPO_ROOT}" <<'PY'
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
platform = "http://forgejo-http.forgejo.svc.cluster.local:3000/idp/platform.git"
hello_app = "http://forgejo-http.forgejo.svc.cluster.local:3000/idp/hello-app.git"


def remote(module: str) -> str:
    return f"{platform}//kubernetes/{module}/base?ref=main"


# Source env directory, gitops directory, remote base that replaces "../..".
seeds = [
    ("kubernetes/argocd/envs/tools", "tools/argocd/argocd", remote("argocd")),
    ("kubernetes/cert-manager/envs/tools", "tools/cert-manager/cert-manager", remote("cert-manager")),
    ("kubernetes/forgejo/envs/tools", "tools/forgejo/forgejo", remote("forgejo")),
    ("kubernetes/forgejo-actions/envs/tools", "tools/forgejo/forgejo-actions", remote("forgejo-actions")),
    ("kubernetes/ingress-nginx/envs/tools", "tools/ingress-nginx/ingress-nginx", remote("ingress-nginx")),
    ("kubernetes/kargo/envs/tools", "tools/kargo/kargo", remote("kargo")),
    ("kubernetes/registry/envs/tools", "tools/registry/registry", remote("registry")),
    ("projects/hello-app/deploy/envs/dev", "nonprod/dev/hello-app", f"{hello_app}//deploy/base?ref=main"),
    ("projects/hello-app/deploy/envs/qa", "nonprod/qa/hello-app", f"{hello_app}//deploy/base?ref=main"),
    ("projects/hello-app/deploy/envs/stage", "nonprod/stage/hello-app", f"{hello_app}//deploy/base?ref=main"),
    ("projects/hello-app/deploy/envs/prod-1", "prod/prod-1/hello-app", f"{hello_app}//deploy/base?ref=main"),
    ("projects/hello-app/deploy/envs/prod-2", "prod/prod-2/hello-app", f"{hello_app}//deploy/base?ref=main"),
]


def skip(path: pathlib.Path) -> bool:
    return "charts" in path.parts or path.name == "runner-token.env"


for source, dest, base in seeds:
    src = repo / source
    if not src.is_dir():
        raise SystemExit(f"missing env {source}")
    for path in src.rglob("*"):
        if not path.is_file() or skip(path):
            continue
        text = path.read_text().replace("- ../..", f"- {base}")
        target = work / dest / path.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
PY

  git -C "${work}" add -A
  git -C "${work}" \
    -c user.name="idp" -c user.email="idp@local" \
    commit -q -m "seed: gitops from ${parent_head}"
  git -C "${work}" push -q origin HEAD:main
}

sync_all() {
  local project_path project

  log "Syncing component bases → platform…"
  sync_platform
  log "platform ✓"
  echo

  log "Seeding gitops when it has no main…"
  seed_gitops
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
  resolve_forgejo || { echo "ERROR: Forgejo is not running." >&2; exit 1; }
  sync_all
fi
