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

# Wait for Deployments and Jobs in one namespace. A namespace with neither is ready.
wait_namespace_workloads() {
  local ns="$1"
  local name
  if kubectl --context "${HOST_CONTEXT}" -n "${ns}" get deploy --no-headers 2>/dev/null | grep -q .; then
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      log "Waiting for ${name} in ${ns}…"
      kubectl --context "${HOST_CONTEXT}" -n "${ns}" rollout status "deployment/${name}" --timeout=300s
    done < <(kubectl --context "${HOST_CONTEXT}" -n "${ns}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  fi
  if kubectl --context "${HOST_CONTEXT}" -n "${ns}" get job --no-headers 2>/dev/null | grep -q .; then
    log "Waiting for jobs in ${ns}…"
    kubectl --context "${HOST_CONTEXT}" -n "${ns}" wait --for=condition=complete job --all --timeout=300s
  fi
}

# Apply bootstrap/clusters/tools/<wave> in directory order and wait for each.
apply_bootstrap() {
  local wave rendered kind namespace name ns_list ns
  local waves=("${REPO_ROOT}/bootstrap/clusters/tools"/*/)
  for wave in "${waves[@]}"; do
    [[ -f "${wave}/kustomization.yaml" ]] || continue
    log "Applying bootstrap $(basename "${wave}")…"
    rendered="$(mktemp)"
    kustomize build --enable-helm "${wave}" > "${rendered}"
    kubectl --context "${HOST_CONTEXT}" apply --server-side -f "${rendered}"
    ns_list=""
    while IFS='|' read -r kind namespace name; do
      [[ -z "${kind}" ]] && continue
      if [[ "${kind}" == "Namespace" ]]; then
        ns_list+="${name}"$'\n'
      elif [[ -n "${namespace}" ]]; then
        ns_list+="${namespace}"$'\n'
      fi
    done < <(kubectl --context "${HOST_CONTEXT}" get -f "${rendered}" \
      -o jsonpath='{range .items[*]}{.kind}{"|"}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}')
    while IFS= read -r ns; do
      [[ -z "${ns}" ]] && continue
      wait_namespace_workloads "${ns}"
    done < <(printf '%s' "${ns_list}" | sort -u)
    rm -f "${rendered}"
  done
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
FORGEJO_SECRETS_DIR="${REPO_ROOT}/kubernetes/forgejo-actions/components/runner-token/secrets"
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

apply_bootstrap

for pid in "${PIDS[@]}"; do wait "${pid}"; done
log "Waiting for vclusters…"
for c in "${VCLUSTERS[@]}"; do
  kubectl --context "${HOST_CONTEXT}" -n "vcluster-${c}" \
    rollout status "statefulset/${c}" --timeout=300s
done

# ---------- 3. Register clusters with Argo CD --------------------------------
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

# ---------- 4. Provision Forgejo repos ----------------------------------------
provision_forgejo_repos

# ---------- 5. Push content to Forgejo repos -----------------------------------
log "Syncing project content to Forgejo…"
"${SCRIPT_DIR}/sync-projects.sh"

# ---------- 6. Activate GitOps -----------------------------------------------
# An empty gitops repo makes the directory generator return an error, and that
# error is requeued after 3m no matter what requeueAfterSeconds says. Create
# the Kargo projects first, let them push the first commit, then apply the
# generator so its first look finds that commit.
APPSET_DIR="${REPO_ROOT}/kubernetes/argocd/resources/applicationsets"
log "Applying Kargo projects…"
kubectl --context "${HOST_CONTEXT}" apply \
  -f "${APPSET_DIR}/kargo-projects.yaml" \
  -f "${APPSET_DIR}/kargo-shared-resources.yaml"

tools_stage_namespaces=()
for stage_file in "${REPO_ROOT}"/kubernetes/kargo/resources/projects/*/stages/tools.yaml; do
  [[ -f "${stage_file}" ]] || continue
  tools_stage_namespaces+=("$(basename "$(dirname "$(dirname "${stage_file}")")")")
done

# 0 when every tools promotion has pushed, 1 while that is still in progress,
# 2 when a promotion failed before the push.
tools_git_pushed() {
  python3 - "$HOST_CONTEXT" "${tools_stage_namespaces[@]}" << 'PY'
import json, subprocess, sys
ctx, expected = sys.argv[1], set(sys.argv[2:])
try:
    raw = subprocess.check_output(
        ["kubectl", "--context", ctx, "get", "promotions.kargo.akuity.io", "-A", "-o", "json"],
        text=True, stderr=subprocess.DEVNULL,
    )
except subprocess.CalledProcessError:
    sys.exit(1)
state = {}
for item in json.loads(raw).get("items") or []:
    if item.get("spec", {}).get("stage") != "tools":
        continue
    ns = item["metadata"]["namespace"]
    if ns not in expected:
        continue
    steps = item.get("spec", {}).get("steps") or []
    meta = {
        entry.get("alias"): entry.get("status")
        for entry in (item.get("status") or {}).get("stepExecutionMetadata") or []
    }
    push_status = None
    for step in steps:
        if step.get("uses") == "git-push":
            push_status = meta.get(step.get("as"))
            break
    phase = (item.get("status") or {}).get("phase") or ""
    if push_status == "Succeeded":
        state[ns] = "pushed"
    elif phase in ("Errored", "Failed") and state.get(ns) != "pushed":
        state[ns] = "failed"
    elif state.get(ns) not in ("pushed", "failed"):
        state[ns] = "pending"
if any(state.get(ns) == "failed" for ns in expected):
    sys.exit(2)
sys.exit(0 if expected and all(state.get(ns) == "pushed" for ns in expected) else 1)
PY
}

log "Waiting for the tools stages to push gitops…"
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  # An if-test consumes the function status, so capture it in the list itself.
  tools_git_pushed && push_status=0 || push_status=$?
  if [[ "${push_status}" -eq 0 ]]; then
    break
  fi
  if [[ "${push_status}" -eq 2 ]]; then
    echo "ERROR: a tools stage failed before pushing gitops." >&2
    "${SCRIPT_DIR}/status.sh" || true
    exit 1
  fi
  sleep 5
done
if ! tools_git_pushed; then
  echo "ERROR: tools stages did not push gitops within 15m." >&2
  "${SCRIPT_DIR}/status.sh" || true
  exit 1
fi

log "Applying root applicationsets Application…"
kubectl --context "${HOST_CONTEXT}" apply -f "${REPO_ROOT}/kubernetes/argocd/bootstrap/root.yaml"

# hello-app waits for an image. The tools stages are already retrying the
# Application lookup, and the generator can see the commit on its first poll.
log "Waiting for the tools stages to finish…"
deadline=$((SECONDS + 900))
promoted=0
while (( SECONDS < deadline )); do
  pending=0
  failed=0
  succeeded=0
  present=" "
  while read -r ns name phase; do
    [[ "${name}" == "tools" ]] || continue
    present+="${ns} "
    case "${phase}" in
      Succeeded) succeeded=$((succeeded + 1)) ;;
      ""|Pending|Running) pending=$((pending + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done < <(kubectl --context "${HOST_CONTEXT}" get stages.kargo.akuity.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.lastPromotion.status.phase}{"\n"}{end}' \
    2>/dev/null || true)

  missing=0
  for ns in "${tools_stage_namespaces[@]}"; do
    [[ "${present}" == *" ${ns} "* ]] || missing=$((missing + 1))
  done

  if (( missing == 0 && pending == 0 && failed == 0 && succeeded == ${#tools_stage_namespaces[@]} )); then
    promoted=1
    break
  fi
  # An Errored promotion does not retry the same freight. Waiting the rest
  # of the deadline cannot change that.
  if (( missing == 0 && pending == 0 && failed > 0 )); then
    echo "ERROR: a tools stage promotion failed." >&2
    "${SCRIPT_DIR}/status.sh" || true
    exit 1
  fi
  sleep 5
done
if [[ "${promoted}" -ne 1 ]]; then
  echo "ERROR: tools stages did not promote within 15m." >&2
  "${SCRIPT_DIR}/status.sh" || true
  exit 1
fi

log "Tools stages have committed gitops. hello-app appears after the first image."
"${SCRIPT_DIR}/status.sh"
