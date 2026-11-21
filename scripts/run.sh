#!/usr/bin/env bash
#
# run.sh
#
# Creates the tools cluster, two vclusters, bootstraps the tools and Kargo, and activates GitOps.
#
# Prerequisites: k3d, kubectl, kustomize, helm, docker, curl, git, python3, openssl
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ---------- check prerequisites ---------------------------------------------
REQUIRED_TOOLS=(k3d kubectl kustomize helm docker curl git python3 openssl)
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

# Wait until every Deployment in a namespace has rolled out.
wait_namespace_deployments() {
  local ns="$1"
  local name found=0
  for _ in $(seq 1 30); do
    if kubectl --context "${HOST_CONTEXT}" -n "${ns}" get deploy --no-headers 2>/dev/null | grep -q .; then
      found=1
      break
    fi
    sleep 2
  done
  if [[ "${found}" -ne 1 ]]; then
    echo "ERROR: no deployments in ${ns} within 60s." >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    log "Waiting for ${name} in ${ns}…"
    kubectl --context "${HOST_CONTEXT}" -n "${ns}" rollout status "deployment/${name}" --timeout=300s
  done < <(kubectl --context "${HOST_CONTEXT}" -n "${ns}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
}

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
# UUID is the UUID encoding of that secret's first 16 bytes. Labels are copied
# from the runner config on every run so registration matches that file.
FORGEJO_SECRETS_DIR="${REPO_ROOT}/kubernetes/forgejo/envs/tools/secrets"
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
fi
runner_labels=$(
  awk '
    BEGIN { in_runner=0; in_labels=0; out="" }
    /^[^ #]/ {
      if ($0 ~ /^runner:/) { in_runner=1; in_labels=0; next }
      in_runner=0
      in_labels=0
    }
    in_runner && /^[[:space:]]*labels:/ { in_labels=1; next }
    in_labels && /^[[:space:]]*-/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      if (out != "") out = out ","
      out = out line
      next
    }
    in_labels { exit }
    END { print out }
  ' "${REPO_ROOT}/kubernetes/forgejo-actions/base/config.yaml"
)
if [[ -z "${runner_labels}" ]]; then
  echo "ERROR: runner config has no labels." >&2
  exit 1
fi
cat > "${FORGEJO_SECRETS_DIR}/runner-token.env" <<EOF
token=${runner_token}
uuid=${runner_uuid}
labels=${runner_labels}
EOF
unset runner_token runner_uuid runner_labels

# ---------- 2. Bootstrap + vclusters ------------------------------------------
log "Bootstrapping the tools cluster…"
kubectl --context "${HOST_CONTEXT}" -n forgejo delete job forgejo-runner-register --ignore-not-found >/dev/null 2>&1 || true
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

# Kargo's admission webhook asks cert-manager for a certificate. The controller
# has to be up before the first promotion, because that promotion is what
# creates gitops main. The other tools arrive in that promotion.
log "Waiting for cert-manager…"
wait_namespace_deployments cert-manager
log "Installing Kargo…"
kustomize build --enable-helm "${REPO_ROOT}/kubernetes/kargo/envs/tools" | \
  kubectl --context "${HOST_CONTEXT}" apply --server-side -f -

log "Waiting for vclusters…"
for c in "${VCLUSTERS[@]}"; do
  kubectl --context "${HOST_CONTEXT}" -n "vcluster-${c}" \
    rollout status "statefulset/${c}" --timeout=300s
done

# ---------- 3. Wait for the hub ----------------------------------------------
wait_for_rollout "${HOST_CONTEXT}" argocd argocd-server &
argocd_wait=$!
log "Waiting for the Forgejo runner registration…"
kubectl --context "${HOST_CONTEXT}" -n forgejo wait \
  --for=condition=complete job/forgejo-runner-register --timeout=300s &
runner_wait=$!
wait "${argocd_wait}"
wait "${runner_wait}"
log "Waiting for Kargo…"
wait_namespace_deployments kargo

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
    -f "${REPO_ROOT}/kubernetes/registry/base/configmap.yaml"
  close_vcluster "${VCLUSTER_PF_PID}"
done

# ---------- 5. Provision Forgejo repos ----------------------------------------
provision_forgejo_repos

# ---------- 6. Push content to Forgejo repos -----------------------------------
log "Syncing project content to Forgejo…"
"${SCRIPT_DIR}/sync-projects.sh"

# ---------- 7. Activate GitOps -----------------------------------------------
log "Applying root applicationsets Application…"
kubectl --context "${HOST_CONTEXT}" apply -f "${REPO_ROOT}/kubernetes/argocd/bootstrap/root.yaml"

# The directory generators watch gitops, which is still empty. The tools
# stages create main and those directories. hello-app waits for an image.
log "Waiting for the tools stages to commit gitops…"
deadline=$((SECONDS + 900))
promoted=0
while (( SECONDS < deadline )); do
  pending=0
  found=0
  while read -r _ name phase; do
    [[ "${name}" == "tools" ]] || continue
    found=1
    [[ "${phase}" == "Succeeded" ]] || pending=1
  done < <(kubectl --context "${HOST_CONTEXT}" get stages.kargo.akuity.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.lastPromotion.status.phase}{"\n"}{end}' \
    2>/dev/null || true)
  if [[ "${found}" -eq 1 && "${pending}" -eq 0 ]]; then
    promoted=1
    break
  fi
  sleep 10
done
if [[ "${promoted}" -ne 1 ]]; then
  echo "ERROR: tools stages did not promote within 15m." >&2
  "${SCRIPT_DIR}/status.sh" || true
  exit 1
fi

log "Tools stages have committed gitops. hello-app appears after the first image."
"${SCRIPT_DIR}/status.sh"
