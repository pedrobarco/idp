#!/usr/bin/env bash
#
# utils.sh
#
# Shared configuration and utility functions sourced by all IDP scripts.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------- Clusters ----------------------------------------------------------
# One k3d node is the hub. The environment clusters are vclusters on it.
HOST_CLUSTER="idp"
HOST_CONTEXT="k3d-${HOST_CLUSTER}"
VCLUSTERS=(nonprod prod)
HUB_CONTEXT="${HOST_CONTEXT}"
VCLUSTER_VERSION="0.37.7"

# ---------- Registry ----------------------------------------------------------
# k3d publishes the registry container on the host. Image names use the
# in-cluster proxy, which this port does not appear in.
REG_NAME="k3d-kind-registry"
REG_PORT="5001"
REG_INTERNAL_PORT="5000"

# Every ingress is served by the tools cluster controller on port 80.
cluster_http_port() {
  echo 80
}

vcluster_api_port() {
  case "$1" in
    nonprod) echo 18443 ;;
    prod) echo 18444 ;;
  esac
}

# ---------- Logging -----------------------------------------------------------
log() { echo "==> $*"; }

# ---------- Cluster helpers ---------------------------------------------------
host_exists() {
  k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${HOST_CLUSTER}"
}

# Start a port-forward to a vcluster API and write a localhost kubeconfig.
# Prints the port-forward pid. Sets VCLUSTER_KUBECONFIG.
open_vcluster() {
  local name="$1"
  local ns="vcluster-${name}"
  local port
  port="$(vcluster_api_port "${name}")"
  mkdir -p "${REPO_ROOT}/.idp"
  VCLUSTER_KUBECONFIG="${REPO_ROOT}/.idp/${name}.kubeconfig"
  python3 - "${name}" "${port}" "${VCLUSTER_KUBECONFIG}" <<'PY'
import base64, json, subprocess, sys
name, port, dest = sys.argv[1:]
raw = subprocess.check_output([
    "kubectl", "--context", "k3d-idp", "-n", f"vcluster-{name}",
    "get", "secret", f"vc-{name}", "-o", "json",
])
data = json.loads(raw)["data"]
text = base64.b64decode(data["config"]).decode()
lines = []
for line in text.splitlines():
    if "server:" in line:
        lines.append(f"    server: https://127.0.0.1:{port}")
    elif "certificate-authority-data:" in line:
        lines.append("    insecure-skip-tls-verify: true")
    else:
        lines.append(line)
text = "\n".join(lines) + "\n"
text = text.replace(
    "name: kubernetes-super-admin@kubernetes", f"name: vcluster-{name}")
text = text.replace(
    "current-context: kubernetes-super-admin@kubernetes",
    f"current-context: vcluster-{name}")
text = text.replace("cluster: kubernetes", f"cluster: vcluster-{name}")
text = text.replace("name: kubernetes\n", f"name: vcluster-{name}\n")
open(dest, "w").write(text)
PY
  kubectl --context "${HOST_CONTEXT}" -n "${ns}" port-forward "svc/${name}" "${port}:443" >/dev/null &
  VCLUSTER_PF_PID=$!
}

close_vcluster() {
  local pid="$1"
  [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
}

# Apply an Argo CD cluster secret for one vcluster, using its admin client cert.
register_vcluster() {
  local name="$1"
  local ns="vcluster-${name}"
  local _ found=0
  # The StatefulSet is ready before vcluster writes its client certificate.
  for _ in $(seq 1 60); do
    if kubectl --context "${HOST_CONTEXT}" -n "${ns}" get secret "vc-${name}" &>/dev/null; then
      found=1
      break
    fi
    sleep 2
  done
  if [[ "${found}" -ne 1 ]]; then
    echo "ERROR: secret ${ns}/vc-${name} was not created within 120s." >&2
    return 1
  fi
  python3 - "${name}" <<'PY' | kubectl --context k3d-idp apply -f -
import json, subprocess, sys
name = sys.argv[1]
ns = f"vcluster-{name}"
raw = subprocess.check_output([
    "kubectl", "--context", "k3d-idp", "-n", ns,
    "get", "secret", f"vc-{name}", "-o", "json",
])
data = json.loads(raw)["data"]
config = {
    "tlsClientConfig": {
        "insecure": False,
        "caData": data["certificate-authority"],
        "certData": data["client-certificate"],
        "keyData": data["client-key"],
    }
}
secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": f"cluster-{name}",
        "namespace": "argocd",
        "labels": {"argocd.argoproj.io/secret-type": "cluster"},
    },
    "stringData": {
        "name": name,
        # The API certificate lists <name>.<namespace>, not the cluster.local form.
        "server": f"https://{name}.{ns}",
        "config": json.dumps(config),
    },
}
json.dump(secret, sys.stdout)
PY
}

wait_for_rollout() {
  local ctx="$1" ns="$2" deploy="$3"
  log "Waiting for ${deploy} in ${ns}…"
  kubectl --context "${ctx}" -n "${ns}" rollout status "deployment/${deploy}" --timeout=300s
}

# ---------- Credential helpers (read from cluster on demand) ------------------
# The Forgejo chart stores the admin user in a secret. The configure-gitea
# init container only holds a secretKeyRef, not the password itself.
_forgejo_admin_field() {
  kubectl --context "${HUB_CONTEXT}" -n forgejo \
    get secret forgejo-admin \
    -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null
}

forgejo_admin_user() { _forgejo_admin_field username; }
forgejo_admin_pass() { _forgejo_admin_field password; }

argocd_admin_pass() {
  kubectl --context "${HUB_CONTEXT}" -n argocd \
    get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null
}

# ---------- Forgejo helpers -----------------------------------------------------
# Port used by the Forgejo port-forward.
FORGEJO_LOCAL_PORT="${FORGEJO_LOCAL_PORT:-3000}"

# PID of the port-forward process (empty if not started by us).
_FORGEJO_PORTFWD_PID=""

# Cleanup handler: kills the port-forward if we started it.
_cleanup_forgejo_portfwd() {
  if [[ -n "${_FORGEJO_PORTFWD_PID}" ]]; then
    kill "${_FORGEJO_PORTFWD_PID}" 2>/dev/null || true
    _FORGEJO_PORTFWD_PID=""
  fi
}

# Lazily resolve Forgejo config and start a port-forward.
# Sets: FORGEJO_ADMIN_USER, FORGEJO_ADMIN_PASS, FORGEJO_URL, FORGEJO_AUTH
# The port-forward is automatically cleaned up on script exit.
resolve_forgejo() {
  [[ -n "${FORGEJO_ADMIN_USER:-}" ]] && return 0
  if ! kubectl --context "${HUB_CONTEXT}" -n forgejo get deployment forgejo &>/dev/null; then
    return 1
  fi
  FORGEJO_ADMIN_USER="$(forgejo_admin_user)"
  FORGEJO_ADMIN_PASS="$(forgejo_admin_pass)"
  FORGEJO_AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASS}"

  # Start a port-forward if one isn't already running on FORGEJO_LOCAL_PORT.
  if ! curl -sf "http://localhost:${FORGEJO_LOCAL_PORT}/api/v1/version" &>/dev/null; then
    log "Starting port-forward to Forgejo on port ${FORGEJO_LOCAL_PORT}…"
    kubectl --context "${HUB_CONTEXT}" -n forgejo \
      port-forward svc/forgejo-http "${FORGEJO_LOCAL_PORT}:3000" &>/dev/null &
    _FORGEJO_PORTFWD_PID=$!
    trap _cleanup_forgejo_portfwd EXIT
    sleep 2
  fi

  FORGEJO_URL="http://localhost:${FORGEJO_LOCAL_PORT}"
}

# Create one empty repo owned by the Forgejo admin. 201 is created, 409 already exists.
_forgejo_create_repo() {
  local user="$1" pass="$2" name="$3" code
  code=$(kubectl --context "${HUB_CONTEXT}" -n forgejo exec deploy/forgejo -c forgejo -- \
    env FORGEJO_USER="${user}" FORGEJO_PASS="${pass}" FORGEJO_REPO="${name}" \
    sh -c 'curl -sS -o /dev/null -w "%{http_code}" -u "${FORGEJO_USER}:${FORGEJO_PASS}" -H "Content-Type: application/json" -X POST http://127.0.0.1:3000/api/v1/user/repos -d "{\"name\":\"${FORGEJO_REPO}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}"')
  case "${code}" in
    201) log "Created Forgejo repo ${name}" ;;
    409) log "Forgejo repo ${name} already exists" ;;
    *)
      echo "ERROR: creating Forgejo repo ${name} returned HTTP ${code}." >&2
      return 1
      ;;
  esac
}

# Create the repos setup publishes: gitops, actions, and each projects/<name>.
provision_forgejo_repos() {
  local user pass project_path
  user="$(forgejo_admin_user)"
  pass="$(forgejo_admin_pass)"
  if [[ -z "${user}" || -z "${pass}" ]]; then
    echo "ERROR: Forgejo admin credentials are unavailable." >&2
    return 1
  fi
  log "Creating Forgejo repositories…"
  _forgejo_create_repo "${user}" "${pass}" gitops
  _forgejo_create_repo "${user}" "${pass}" actions
  for project_path in "${REPO_ROOT}/projects"/*/; do
    [[ -d "${project_path}" ]] || continue
    _forgejo_create_repo "${user}" "${pass}" "$(basename "${project_path}")"
  done
}
