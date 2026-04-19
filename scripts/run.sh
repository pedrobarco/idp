#!/usr/bin/env bash
#
# run.sh
#
# Creates kind clusters, bootstraps infrastructure, and activates GitOps.
#
# Prerequisites: kind, kubectl, kustomize, helm, docker, curl, git, terraform
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

TF_DIR="${REPO_ROOT}/terraform"

# ---------- check prerequisites ---------------------------------------------
REQUIRED_TOOLS=(kind kubectl kustomize helm docker curl git terraform)
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

# ---------- 0. Provision registry + Kind clusters via Terraform ---------------
log "Provisioning registry and Kind clusters…"
[[ -d "${TF_DIR}/clusters/.terraform" ]] || terraform -chdir="${TF_DIR}/clusters" init -input=false
terraform -chdir="${TF_DIR}/clusters" apply -auto-approve -input=false

# ---------- 1. Generate placeholder secret env files --------------------------
# The argocd-manager SA doesn't exist until after bootstrap, so we write
# placeholder env files first so kustomize secretGenerator can build.
# Real credentials are patched in step 4.
CLUSTER_SECRETS_DIR="${REPO_ROOT}/bootstrap/dev/cluster-secrets/secrets"
mkdir -p "${CLUSTER_SECRETS_DIR}"

for c in "${CLUSTERS[@]}"; do
  local_server="https://${c}-control-plane:6443"
  [[ "${c}" == "${HUB_CLUSTER}" ]] && local_server="https://kubernetes.default.svc"
  cat > "${CLUSTER_SECRETS_DIR}/${c}.env" <<ENV
name=${c}
server=${local_server}
config={}
ENV
done

# Generate a shared runner registration token.
# Both Gitea (env var) and the Actions runner (env var) reference this secret.
# The secretGenerator in infrastructure/gitea creates the K8s Secret at bootstrap.
GITEA_SECRETS_DIR="${REPO_ROOT}/infrastructure/gitea/secrets"
mkdir -p "${GITEA_SECRETS_DIR}"
cat > "${GITEA_SECRETS_DIR}/runner-token.env" <<EOF
token=$(openssl rand -hex 24)
EOF

# ---------- 2. Build images + bootstrap all clusters (parallel) ---------------
log "Building images and bootstrapping clusters…"

BUILD_PIDS=()
for project_dir in "${REPO_ROOT}"/projects/*/; do
  [[ -f "${project_dir}/Dockerfile" ]] || continue
  project_name="$(basename "${project_dir}")"
  "${REPO_ROOT}/scripts/build.sh" \
    --repo "${project_name}" --tag latest --context "${project_dir}" &
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

# ---------- 3. Wait for infrastructure (parallel) ----------------------------
wait_for_rollout "${HUB_CONTEXT}" argocd argocd-server &
wait_for_rollout "${HUB_CONTEXT}" gitea gitea &
for c in "${CLUSTERS[@]}"; do
  wait_for_rollout "kind-${c}" ingress-nginx ingress-nginx-controller &
done
wait

# ---------- 4. Populate real cluster credentials (parallel) -------------------
# argocd-manager SA now exists. Regenerate env files with real tokens,
# then re-apply the cluster secrets.
generate_cluster_env() {
  local c="$1" remote_ctx="kind-${c}"
  log "Generating credentials for cluster '${c}'…"

  local server="https://${c}-control-plane:6443"
  local token ca_data config
  token=$(kubectl --context "${remote_ctx}" -n kube-system \
    create token argocd-manager --duration=87600h)
  ca_data=$(kubectl --context "${remote_ctx}" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-${c}\")].cluster.certificate-authority-data}")

  config="{\"bearerToken\":\"${token}\",\"tlsClientConfig\":{\"insecure\":false,\"caData\":\"${ca_data}\"}}"

  cat > "${CLUSTER_SECRETS_DIR}/${c}.env" <<ENV
name=${c}
server=${server}
config=${config}
ENV
}

PIDS=()
for c in "${CLUSTERS[@]}"; do
  [[ "${c}" == "${HUB_CLUSTER}" ]] && continue
  generate_cluster_env "${c}" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}"; done

log "Re-applying cluster secrets with real credentials…"
kustomize build "${REPO_ROOT}/bootstrap/dev/cluster-secrets" | \
  kubectl --context "${HUB_CONTEXT}" apply --server-side -f -

# ---------- 5. Provision Gitea repos via Terraform ----------------------------
resolve_gitea || { echo "ERROR: Gitea is not running." >&2; exit 1; }

GITEA_LOCAL_PORT=3000
kubectl --context "${HUB_CONTEXT}" -n gitea port-forward svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &
PORTFWD_PID=$!
trap "kill ${PORTFWD_PID} 2>/dev/null || true" EXIT
sleep 2

log "Provisioning Gitea repositories…"
[[ -d "${TF_DIR}/repositories/.terraform" ]] || terraform -chdir="${TF_DIR}/repositories" init -input=false
terraform -chdir="${TF_DIR}/repositories" apply -auto-approve -input=false \
  -var "gitea_url=http://localhost:${GITEA_LOCAL_PORT}" \
  -var "gitea_username=${GITEA_ADMIN_USER}" \
  -var "gitea_password=${GITEA_ADMIN_PASS}"

kill "${PORTFWD_PID}" 2>/dev/null || true
trap - EXIT

# ---------- 6. Push content to Gitea repos ------------------------------------
log "Syncing project content to Gitea…"
"${SCRIPT_DIR}/sync-projects.sh"

# ---------- 7. Activate GitOps -----------------------------------------------
# Apply the root Application that tracks applicationsets/.
# ArgoCD will auto-discover and apply all ApplicationSets in that directory.
log "Applying root applicationsets Application…"
kubectl --context "${HUB_CONTEXT}" apply -f "${REPO_ROOT}/applicationsets/applicationsets.yaml"

log "Done! ArgoCD will now reconcile all workload applications."
"${SCRIPT_DIR}/status.sh"
