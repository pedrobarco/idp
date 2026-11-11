#!/usr/bin/env bash
#
# run.sh
#
# Creates the tools cluster, two vclusters, bootstraps the tools, and activates GitOps.
#
# Prerequisites: k3d, kubectl, kustomize, helm, docker, curl, git, terraform, python3
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

TF_DIR="${REPO_ROOT}/terraform"

# ---------- check prerequisites ---------------------------------------------
REQUIRED_TOOLS=(k3d kubectl kustomize helm docker curl git terraform python3)
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

if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon is not running." >&2
  exit 1
fi

# ---------- 0. Registry + k3d host -------------------------------------------
if ! k3d registry list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${REG_NAME}"; then
  log "Creating registry ${REG_NAME}…"
  k3d registry create kind-registry --port "127.0.0.1:${REG_PORT}"
fi

if ! host_exists; then
  log "Creating k3d cluster '${HOST_CLUSTER}'…"
  k3d cluster create --config "${REPO_ROOT}/k3d/idp.yaml"
else
  log "k3d cluster '${HOST_CLUSTER}' already exists"
fi

# ---------- 1. Runner secret --------------------------------------------------
# Forgejo offline registration wants a 40-character hex secret. The runner
# UUID is the UUID encoding of that secret's first 16 bytes.
FORGEJO_SECRETS_DIR="${REPO_ROOT}/gitops/clusters/tools/forgejo/forgejo/secrets"
mkdir -p "${FORGEJO_SECRETS_DIR}"
runner_token=""
runner_uuid=""
if [[ -f "${FORGEJO_SECRETS_DIR}/runner-token.env" ]]; then
  runner_token=$(sed -n 's/^token=//p' "${FORGEJO_SECRETS_DIR}/runner-token.env")
  runner_uuid=$(sed -n 's/^uuid=//p' "${FORGEJO_SECRETS_DIR}/runner-token.env")
fi
if [[ ! "${runner_token}" =~ ^[0-9a-f]{40}$ || -z "${runner_uuid}" ]]; then
  runner_token=$(openssl rand -hex 20)
  runner_uuid=$(python3 -c 'import sys, uuid; print(uuid.UUID(bytes=sys.argv[1][:16].encode()))' "${runner_token}")
  cat > "${FORGEJO_SECRETS_DIR}/runner-token.env" <<EOF
token=${runner_token}
uuid=${runner_uuid}
EOF
fi
unset runner_token runner_uuid

# ---------- 2. Images + host bootstrap + vclusters ----------------------------
log "Building images and bootstrapping the tools cluster…"

BUILD_PIDS=()
for project_dir in "${REPO_ROOT}"/projects/*/; do
  [[ -f "${project_dir}/Dockerfile" ]] || continue
  project_name="$(basename "${project_dir}")"
  "${REPO_ROOT}/actions/build.sh" \
    --repo "${project_name}" --context "${project_dir}" &
  BUILD_PIDS+=($!)
done

kustomize build --enable-helm "${REPO_ROOT}/bootstrap/tools" | \
  kubectl --context "${HOST_CONTEXT}" apply --server-side -f -

helm repo add loft https://charts.loft.sh >/dev/null 2>&1 || true
helm repo update loft >/dev/null

log "Installing vclusters…"
PIDS=()
for c in "${VCLUSTERS[@]}"; do
  helm upgrade --install "${c}" loft/vcluster --version "${VCLUSTER_VERSION}" \
    --namespace "vcluster-${c}" --create-namespace \
    --kube-context "${HOST_CONTEXT}" \
    -f "${REPO_ROOT}/bootstrap/vclusters/values.yaml" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "${pid}"; done
for pid in "${BUILD_PIDS[@]}"; do wait "${pid}"; done

log "Waiting for vclusters…"
for c in "${VCLUSTERS[@]}"; do
  kubectl --context "${HOST_CONTEXT}" -n "vcluster-${c}" \
    rollout status "statefulset/${c}" --timeout=300s
done

# ---------- 3. Wait for the hub ----------------------------------------------
wait_for_rollout "${HOST_CONTEXT}" argocd argocd-server &
argocd_wait=$!
wait_for_rollout "${HOST_CONTEXT}" forgejo forgejo &
forgejo_wait=$!
wait "${argocd_wait}"
wait "${forgejo_wait}"

register_forgejo_runner

# ---------- 4. Register clusters with Argo CD --------------------------------
log "Registering the tools cluster and vclusters with Argo CD…"
kubectl --context "${HOST_CONTEXT}" -n argocd apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cluster-tools
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: tools
  server: https://kubernetes.default.svc
  config: "{}"
EOF

for c in "${VCLUSTERS[@]}"; do
  register_vcluster "${c}"
  open_vcluster "${c}"
  for _ in $(seq 1 30); do
    if KUBECONFIG="${VCLUSTER_KUBECONFIG}" kubectl get --raw=/readyz &>/dev/null; then
      break
    fi
    sleep 1
  done
  # The configmap documents the local registry for anything running in the vcluster.
  KUBECONFIG="${VCLUSTER_KUBECONFIG}" kubectl apply --server-side \
    -f "${REPO_ROOT}/gitops/infrastructure/registry/configmap.yaml"
  close_vcluster "${VCLUSTER_PF_PID}"
done

# ---------- 5. Provision Forgejo repos via Terraform ---------------------------
resolve_forgejo || { echo "ERROR: Forgejo is not running." >&2; exit 1; }

log "Provisioning Forgejo repositories…"
[[ -d "${TF_DIR}/repositories/.terraform" ]] || terraform -chdir="${TF_DIR}/repositories" init -input=false
terraform -chdir="${TF_DIR}/repositories" apply -auto-approve -input=false \
  -var "gitea_url=${FORGEJO_URL}" \
  -var "gitea_username=${FORGEJO_ADMIN_USER}" \
  -var "gitea_password=${FORGEJO_ADMIN_PASS}"

# ---------- 6. Push content to Forgejo repos -----------------------------------
log "Syncing project content to Forgejo…"
"${SCRIPT_DIR}/sync-projects.sh"

# ---------- 7. Activate GitOps -----------------------------------------------
log "Applying root applicationsets Application…"
kubectl --context "${HOST_CONTEXT}" apply -f "${REPO_ROOT}/gitops/applicationsets/applicationsets.yaml"

log "Done! ArgoCD will now reconcile all workload applications."
"${SCRIPT_DIR}/status.sh"
