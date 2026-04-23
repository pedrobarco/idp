#!/usr/bin/env bash
#
# status.sh — IDP platform status
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ---------- Formatting -------------------------------------------------------
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"

COL="  %-40s %-18s %-42s %s\n"

header() {
  printf "${DIM}  %-40s %-18s %-42s %s${RESET}\n" "NAME" "STATUS" "URL" "CREDENTIALS"
  printf "${DIM}  %-40s %-18s %-42s %s${RESET}\n" \
    "────────────────────────────────────────" \
    "──────────────────" \
    "──────────────────────────────────────────" \
    "────────────────────"
}

section() {
  printf "\n  ${BOLD}%s${RESET}\n" "$1"
}

color_status() {
  local status="$1"
  case "${status}" in
    Synced/Healthy|Healthy)  printf "${GREEN}%s${RESET}" "${status}" ;;
    *Progressing*|*Unknown*) printf "${YELLOW}%s${RESET}" "${status}" ;;
    *)                       printf "${RED}%s${RESET}" "${status}" ;;
  esac
}

row() {
  local name="$1" status="$2" url="${3:--}" creds="${4:--}"
  local colored
  colored=$(color_status "${status}")
  # color_status adds ANSI codes; pad manually to account for invisible chars
  local pad=$(( 18 - ${#status} ))
  printf "  %-40s %s%${pad}s %-42s %s\n" "${name}" "${colored}" "" "${url}" "${creds}"
}

# ---------- Helpers -----------------------------------------------------------
cluster_port() {
  docker inspect "${1}-control-plane" \
    --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' 2>/dev/null || echo "?"
}

ingress_url() {
  local ctx="$1" ns="$2" name="$3"
  local host port
  host=$(kubectl --context "${ctx}" -n "${ns}" get ingress "${name}" \
    -o jsonpath='{.spec.rules[0].host}' 2>/dev/null) || return
  [[ -z "${host}" ]] && return
  port=$(cluster_port "${ctx#kind-}")
  [[ "${port}" == "80" ]] && echo "http://${host}" || echo "http://${host}:${port}"
}

# Check if all deployments in a namespace are ready
ns_status() {
  local ctx="$1" ns="$2"
  local total ready
  total=$(kubectl --context "${ctx}" -n "${ns}" get deployments --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl --context "${ctx}" -n "${ns}" get deployments --no-headers 2>/dev/null | \
    awk '$2 ~ /^[0-9]+\/[0-9]+$/ { split($2,a,"/"); if(a[1]==a[2]) c++ } END { print c+0 }')
  if [[ "${total}" -eq 0 ]]; then
    echo "NotFound"
  elif [[ "${ready}" -eq "${total}" ]]; then
    echo "Healthy"
  else
    echo "Progressing (${ready}/${total})"
  fi
}

# ---------- Output -----------------------------------------------------------
echo ""
header

ARGOCD_PASS="$(argocd_admin_pass 2>/dev/null || echo '?')"
ARGOCD_URL=$(ingress_url "${HUB_CONTEXT}" argocd argocd-server 2>/dev/null || echo "-")
ARGOCD_STATUS=$(ns_status "${HUB_CONTEXT}" argocd)

GITEA_USER="$(gitea_admin_user 2>/dev/null || echo '?')"
GITEA_PASS="$(gitea_admin_pass 2>/dev/null || echo '?')"
GITEA_URL=$(ingress_url "${HUB_CONTEXT}" gitea gitea 2>/dev/null || echo "-")
GITEA_STATUS=$(ns_status "${HUB_CONTEXT}" gitea)

row "argocd" "${ARGOCD_STATUS}" "${ARGOCD_URL}" "admin / ${ARGOCD_PASS}"
row "gitea"  "${GITEA_STATUS}"  "${GITEA_URL}"  "${GITEA_USER} / ${GITEA_PASS}"

# Discover ingress info by label in a namespace.
# Sets: _DISCOVER_URL, _DISCOVER_CREDS
discover_ingress() {
  local ctx="$1" ns="$2"
  _DISCOVER_URL="" _DISCOVER_CREDS=""

  # Find the ingress labeled part-of=idp
  local json
  json=$(kubectl --context "${ctx}" -n "${ns}" get ingress \
    -l "app.kubernetes.io/part-of=idp" --no-headers \
    -o jsonpath='{.items[0].spec.rules[0].host} {.items[0].metadata.annotations.idp\.localhost/credentials-secret} {.items[0].metadata.annotations.idp\.localhost/credentials-keys}' \
    2>/dev/null) || return
  local host secret_name keys_csv
  read -r host secret_name keys_csv <<< "${json}"
  [[ -z "${host}" || "${host}" == " " ]] && return

  # Build URL
  local port
  port=$(cluster_port "${ctx#kind-}")
  [[ "${port}" == "80" ]] && _DISCOVER_URL="http://${host}" || _DISCOVER_URL="http://${host}:${port}"

  # Build credentials from annotated secret + keys
  [[ -z "${secret_name}" || "${secret_name}" == " " ]] && return
  [[ -z "${keys_csv}" || "${keys_csv}" == " " ]] && return
  local IFS=',' parts=()
  for key in ${keys_csv}; do
    local val
    val=$(kubectl --context "${ctx}" -n "${ns}" get secret "${secret_name}" \
      -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null) || continue
    [[ -n "${val}" ]] && parts+=("${val}")
  done
  if [[ ${#parts[@]} -gt 0 ]]; then
    local result="${parts[0]}"
    for ((i=1; i<${#parts[@]}; i++)); do
      result+=" / ${parts[$i]}"
    done
    _DISCOVER_CREDS="${result}"
  fi
}

kubectl --context "${HUB_CONTEXT}" -n argocd get applicationsets \
  --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | while read -r appset; do
    section "${appset}"
    kubectl --context "${HUB_CONTEXT}" -n argocd get applications \
      -l "app.kubernetes.io/name=${appset}" --no-headers \
      -o custom-columns='NAME:.metadata.name,CLUSTER:.metadata.labels.app\.kubernetes\.io/cluster,NS:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status' \
      2>/dev/null | while read -r name cluster ns sync health; do
        ctx="kind-${cluster}"
        discover_ingress "${ctx}" "${ns}" 2>/dev/null || true
        row "${name}" "${sync}/${health}" "${_DISCOVER_URL:-"-"}" "${_DISCOVER_CREDS}"
      done
  done

echo ""
