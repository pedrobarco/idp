#!/usr/bin/env bash
#
# sync-projects.sh
#
# Publishes folders from this repo to Forgejo. This repo stays a GitHub
# history: the script never commits, merges, or adds remotes here.
#
#   gitops/            → gitops
#   actions/           → actions
#   projects/<name>/   → <name>
#
# Each Forgejo repo is cloned under .sync/ (gitignored). actions and projects
# are copied onto Forgejo main. gitops is merged onto it instead, so commits
# Kargo made after the last sync stay in the tree. A merge conflict stops the
# sync. Other repos are force-pushed with --force-with-lease when Forgejo
# moved during the sync.
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

# Most recent "sync: update gitops from <sha>" commit on Forgejo main.
# Empty when this repo has never been published there.
latest_gitops_sync_commit() {
  local work="$1"
  git -C "${work}" log -1 --grep='^sync: update gitops from ' --format='%H' 2>/dev/null || true
}

# Merge the local gitops tree onto the Forgejo checkout.
# The merge base is the last sync commit. Files unchanged locally keep the
# Forgejo copy, which is where Kargo's image tags live. Files changed on both
# sides are merged; a conflict leaves the checkout untouched and stops.
merge_local_onto_forgejo() {
  local work="$1"
  local local_root="$2"
  local base="$3"
  if python3 - "${work}" "${local_root}" "${base}" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

work = pathlib.Path(sys.argv[1])
local_root = pathlib.Path(sys.argv[2])
base = sys.argv[3]


def skip(rel: str) -> bool:
    parts = pathlib.PurePosixPath(rel).parts
    return ".git" in parts or "charts" in parts


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def blob(rel: str) -> bytes | None:
    result = subprocess.run(
        ["git", "-C", str(work), "show", f"{base}:{rel}"],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def walk(root: pathlib.Path) -> set[str]:
    found = set()
    if not root.exists():
        return found
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if skip(rel):
            continue
        found.add(rel)
    return found


def split_images(data: bytes | None) -> tuple[bytes | None, bytes | None]:
    """Split a trailing top-level images: block from the rest of a YAML file."""
    if data is None:
        return None, None
    lines = data.decode().splitlines()
    start = next((i for i, line in enumerate(lines) if line == "images:"), None)
    if start is None:
        return data, None
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line and not line.startswith((" ", "\t", "-")):
            break
        end += 1
    if any(line for line in lines[end:]):
        return data, None
    body = "\n".join(lines[:start]).rstrip("\n")
    body_bytes = (body + "\n").encode() if body else b""
    images = ("\n".join(lines[start:end]).rstrip("\n") + "\n").encode()
    return body_bytes, images


def whitespace_equal(left: bytes | None, right: bytes | None) -> bool:
    if left is None or right is None:
        return left is right
    if left == right:
        return True
    with tempfile.TemporaryDirectory() as tmp:
        directory = pathlib.Path(tmp)
        (directory / "left").write_bytes(left)
        (directory / "right").write_bytes(right)
        result = subprocess.run(
            [
                "git",
                "diff",
                "--no-index",
                "--quiet",
                "-w",
                "--ignore-blank-lines",
                "--",
                str(directory / "left"),
                str(directory / "right"),
            ],
            capture_output=True,
        )
    return result.returncode == 0


def join(body: bytes, images: bytes | None) -> bytes:
    if not images:
        return body if body.endswith(b"\n") or body == b"" else body + b"\n"
    return body.rstrip(b"\n") + b"\n\n" + images


def choose_images(
    rel: str,
    base_images: bytes | None,
    local_images: bytes | None,
    forgejo_images: bytes | None,
) -> bytes | None:
    if local_images == base_images:
        return forgejo_images
    if forgejo_images == base_images:
        return local_images
    if local_images == forgejo_images:
        return local_images
    fail(f"merge conflict in {rel}: both sides changed the images block")
    return None


base_files = {
    line
    for line in subprocess.check_output(
        ["git", "-C", str(work), "ls-tree", "-r", "--name-only", base],
        text=True,
    ).splitlines()
    if line and not skip(line)
}
local_files = walk(local_root)
head_files = walk(work)

for rel in sorted(base_files | local_files | head_files):
    base_bytes = blob(rel) if rel in base_files else None
    local_path = local_root / rel
    local_bytes = local_path.read_bytes() if local_path.is_file() else None
    dest = work / rel
    forgejo_bytes = dest.read_bytes() if dest.is_file() else None

    # This repo did not change the file. Keep Forgejo's copy.
    if local_bytes == base_bytes:
        continue
    # The local deletion matches the last sync. Forgejo has nothing newer.
    if local_bytes is None and forgejo_bytes == base_bytes:
        dest.unlink(missing_ok=True)
        continue
    # Forgejo still matches the last sync, and both sides agree on images.
    # A missing local images block is not agreement: the sync commit records
    # Kargo's tags, and the local tree never carries them.
    if forgejo_bytes == base_bytes and local_bytes is not None:
        _, local_images = split_images(local_bytes)
        _, forgejo_images = split_images(forgejo_bytes)
        if local_images == forgejo_images:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(local_bytes)
            continue
    if local_bytes == forgejo_bytes:
        continue
    if local_bytes is None or forgejo_bytes is None or base_bytes is None:
        fail(f"cannot merge {rel}: it was added or removed on both sides")
    if b"\0" in local_bytes or b"\0" in forgejo_bytes or b"\0" in base_bytes:
        fail(f"cannot merge binary file {rel}")

    base_body, base_images = split_images(base_bytes)
    local_body, local_images = split_images(local_bytes)
    forgejo_body, forgejo_images = split_images(forgejo_bytes)
    # The local tree does not store image tags. Absence must not delete the
    # block a previous sync kept, or the one Kargo wrote after that sync.
    if local_images is None:
        images = forgejo_images
    else:
        images = choose_images(rel, base_images, local_images, forgejo_images)

    # Kargo rewrites indentation when it sets an image. Ignore that and keep
    # the local body when the only real Forgejo change is the images block.
    if whitespace_equal(base_body, forgejo_body):
        body = local_body if local_body is not None else b""
    elif whitespace_equal(base_body, local_body):
        body = forgejo_body if forgejo_body is not None else b""
    else:
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / "local").write_bytes(local_body or b"")
            (directory / "base").write_bytes(base_body or b"")
            (directory / "forgejo").write_bytes(forgejo_body or b"")
            merged = subprocess.run(
                [
                    "git",
                    "merge-file",
                    "-p",
                    "--diff3",
                    "-L",
                    "local",
                    "-L",
                    "last-sync",
                    "-L",
                    "forgejo",
                    str(directory / "local"),
                    str(directory / "base"),
                    str(directory / "forgejo"),
                ],
                capture_output=True,
            )
        if merged.returncode != 0:
            sys.stderr.buffer.write(merged.stdout)
            fail(f"merge conflict in {rel}")
        body = merged.stdout

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(join(body, images))
PY
  then
    return 0
  fi
  git -C "${work}" reset --hard -q
  git -C "${work}" clean -fd -q
  return 1
}

# Copy one local folder onto its Forgejo checkout, replacing the previous tree.
replace_tree() {
  local prefix="$1"
  local work="$2"
  rsync -a --delete --exclude '.git/' --exclude 'charts/' "${REPO_ROOT}/${prefix}/" "${work}/"
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

  local base=""
  if [[ "${name}" == "gitops" ]]; then
    base="$(latest_gitops_sync_commit "${work}")"
  fi
  if [[ -n "${base}" ]]; then
    merge_local_onto_forgejo "${work}" "${REPO_ROOT}/${prefix}" "${base}"
    find "${work}" -type d -name charts -prune -exec rm -rf {} +
  else
    replace_tree "${prefix}" "${work}"
  fi
  git -C "${work}" add -A
  if ! git -C "${work}" diff --cached --quiet; then
    git -C "${work}" \
      -c user.name="idp" -c user.email="idp@local" \
      commit -q -m "sync: update ${name} from ${parent_head}"
  fi

  if git -C "${work}" push -q origin HEAD:main; then
    return 0
  fi

  # gitops must not rewrite main: that drops Kargo's commits.
  if [[ -n "${base}" ]]; then
    echo "ERROR: Forgejo gitops main moved while publishing. Re-run make sync." >&2
    return 1
  fi

  # Forgejo moved, or the local checkout diverged. Rebase onto it and rewrite.
  fetch_origin_main "${work}"
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
  resolve_forgejo || { echo "ERROR: Forgejo is not running." >&2; exit 1; }
  sync_all
fi
