#!/usr/bin/env bash
#
# run.sh
#
# Creates kind clusters, bootstraps infrastructure, and activates GitOps.
#
# Prerequisites: kind, kubectl, kustomize, helm, docker, curl, git
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

KIND_DIR="${REPO_ROOT}/kind"

# ---------- check prerequisites ---------------------------------------------
REQUIRED_TOOLS=(kind kubectl kustomize helm docker curl git)
missing=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "${tool}" &>/dev/null; then
    missing+=("${tool}")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required tools: ${missing[*]}" >&2
  echo "Please install them before running this script." >&2
  exit 1
fi

# Verify Docker daemon is running
if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon is not running." >&2
  exit 1
fi

# ---------- 0. Local Docker registry -----------------------------------------

if docker inspect "${REG_NAME}" &>/dev/null; then
  log "Registry '${REG_NAME}' already exists — ensuring it is running."
  docker start "${REG_NAME}" 2>/dev/null || true
else
  log "Creating local registry '${REG_NAME}' on host port ${REG_PORT}…"
  docker run -d --restart=always \
    -p "127.0.0.1:${REG_PORT}:${REG_INTERNAL_PORT}" \
    --name "${REG_NAME}" registry:2
fi

# ---------- 1. Create clusters (parallel) ------------------------------------
create_cluster() {
  local c="$1"
  if cluster_exists "${c}"; then
    log "Cluster '${c}' already exists — skipping."
  else
    log "Creating cluster '${c}'…"
    kind create cluster --config "${KIND_DIR}/${c}.yaml"
  fi
  # Connect to shared Docker network
  docker network connect kind "${c}-control-plane" 2>/dev/null || true
  # Configure containerd to use the local registry
  for node in $(kind get nodes --name "${c}" 2>/dev/null); do
    docker exec "${node}" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
    cat <<TOML | docker exec -i "${node}" cp /dev/stdin "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml"
[host."http://${REG_NAME}:${REG_INTERNAL_PORT}"]
TOML
  done
}

PIDS=()
for c in "${CLUSTERS[@]}"; do
  create_cluster "${c}" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}"; done

docker network connect kind "${REG_NAME}" 2>/dev/null || true

# ---------- 2. Build images + bootstrap all clusters (parallel) --------------
log "Building images and bootstrapping clusters…"

BUILD_PIDS=()
for build_script in "${REPO_ROOT}"/projects/*/ci/build.sh; do
  [[ -f "${build_script}" ]] || continue
  "${build_script}" --tag latest &
  BUILD_PIDS+=($!)
done

PIDS=()
for c in "${CLUSTERS[@]}"; do
  (
    log "Bootstrapping cluster '${c}'…"
    kustomize build --enable-helm "${REPO_ROOT}/bootstrap/${c}" | \
      kubectl --context "kind-${c}" apply --server-side -f -
  ) &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}"; done
for pid in "${BUILD_PIDS[@]}"; do wait "${pid}"; done

# ---------- 3. Wait for infrastructure (parallel) ---------------------------
wait_for_rollout "${HUB_CONTEXT}" argocd argocd-server &
wait_for_rollout "${HUB_CONTEXT}" gitea gitea &
for c in "${CLUSTERS[@]}"; do
  wait_for_rollout "kind-${c}" ingress-nginx ingress-nginx-controller &
done
wait

# ---------- 4. Patch cluster secrets with real credentials (parallel) --------
# argocd-manager SA now exists on each remote cluster. Generate tokens and
# patch the cluster secrets so ArgoCD can authenticate.
patch_cluster_secret() {
  local c="$1" remote_ctx="kind-${c}"
  log "Patching credentials for cluster '${c}'…"

  local token ca_data
  token=$(kubectl --context "${remote_ctx}" -n kube-system \
    create token argocd-manager --duration=87600h)
  ca_data=$(kubectl --context "${remote_ctx}" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-${c}\")].cluster.certificate-authority-data}")

  kubectl --context "${HUB_CONTEXT}" -n argocd patch secret "cluster-${c}" \
    -p "{\"stringData\":{\"config\":\"{\\\"bearerToken\\\":\\\"${token}\\\",\\\"tlsClientConfig\\\":{\\\"insecure\\\":false,\\\"caData\\\":\\\"${ca_data}\\\"}}\" }}"
}

PIDS=()
for c in "${CLUSTERS[@]}"; do
  [[ "${c}" == "${HUB_CLUSTER}" ]] && continue
  patch_cluster_secret "${c}" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}"; done

# ---------- 5. Sync repos to Gitea -------------------------------------------
log "Syncing projects to Gitea…"
"${SCRIPT_DIR}/sync-projects.sh"

# ---------- 6. Activate GitOps -----------------------------------------------
# Apply the root Application that tracks applicationsets/.
# ArgoCD will auto-discover and apply all ApplicationSets in that directory.
log "Applying root applicationsets Application…"
kubectl --context "${HUB_CONTEXT}" apply -f "${REPO_ROOT}/applicationsets/applicationsets.yaml"

log "Done! ArgoCD will now reconcile all workload applications."
"${SCRIPT_DIR}/status.sh"
