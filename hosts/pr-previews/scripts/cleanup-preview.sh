#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER=${1:?missing PR number}
WORKSPACE=${2:-Satchel}

PREVIEW_BASE="${PREVIEW_BASE:-/var/lib/pr-previews}"
INSTANCES_DIR="${PREVIEW_BASE}/instances"
LOCK_DIR="${PREVIEW_BASE}/locks"
PORTS_FILE="${PREVIEW_BASE}/used-ports.txt"
TRAEFIK_CONFIG_DIR="${TRAEFIK_CONFIG_DIR:-/etc/traefik/dynamic}"
SYSTEMCTL_HELPER="${PR_PREVIEW_SYSTEMCTL:-preview-systemctl}"
: "${SUDO:=sudo}"
: "${RM:=rm}"

if [[ ! "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo '{"status":"error","message":"pr_number must be numeric"}'
  exit 1
fi

WORKSPACE_LOWER="$(printf "%s" "${WORKSPACE}" | tr '[:upper:]' '[:lower:]')"
case "${WORKSPACE_LOWER}" in
  satchel) ;;
  *)
    echo '{"status":"error","message":"unsupported workspace"}'
    exit 1
    ;;
esac

INSTANCE_ID="pr-${PR_NUMBER}-${WORKSPACE_LOWER}"
INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_ID}"
LOCK_FILE="${LOCK_DIR}/${INSTANCE_ID}.lock"
PORT_LOCK_FILE="${LOCK_DIR}/ports.lock"
ROUTE_FILE="${TRAEFIK_CONFIG_DIR}/${INSTANCE_ID}.yml"
LEGACY_PR_DIR="${PREVIEW_BASE}/monorepo-pr-${PR_NUMBER}"
LEGACY_META_DIR="${PREVIEW_BASE}/pr-${PR_NUMBER}"

mkdir -p "${LOCK_DIR}" "${INSTANCES_DIR}"
touch "${PORTS_FILE}"

json_response() {
  local status=$1
  local message=$2
  jq -n \
    --arg status "${status}" \
    --arg message "${message}" \
    --arg instance_id "${INSTANCE_ID}" \
    '{status:$status,message:$message,instance_id:$instance_id}'
}

release_port() {
  (
    flock -x 9
    grep -v "^${INSTANCE_ID} " "${PORTS_FILE}" > "${PORTS_FILE}.tmp" || true
    mv "${PORTS_FILE}.tmp" "${PORTS_FILE}"
  ) 9>"${PORT_LOCK_FILE}"
}

cleanup_mounts() {
  local dir=$1
  if [ -d "${dir}/local" ]; then
    if command -v findmnt >/dev/null 2>&1 && findmnt -no TARGET "${dir}/local" >/dev/null 2>&1; then
      ${SUDO} umount -l "${dir}/local" || true
    elif command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${dir}/local"; then
      ${SUDO} umount -l "${dir}/local" || true
    fi
  fi
}

(
  flock -x 9

  echo "=== Cleaning up ${INSTANCE_ID} ===" >&2

  ${SUDO} "${SYSTEMCTL_HELPER}" stop-deploy "${INSTANCE_ID}" >/dev/null 2>&1 || true
  ${SUDO} "${SYSTEMCTL_HELPER}" stop "${INSTANCE_ID}" >/dev/null 2>&1 || true
  ${SUDO} "${SYSTEMCTL_HELPER}" reset-failed "${INSTANCE_ID}" >/dev/null 2>&1 || true

  ${RM} -f -- "${ROUTE_FILE}"
  release_port

  cleanup_mounts "${INSTANCE_DIR}/repo"
  cleanup_mounts "${LEGACY_PR_DIR}"

  command -v chattr >/dev/null 2>&1 && ${SUDO} chattr -R -i "${INSTANCE_DIR}" 2>/dev/null || true
  command -v chattr >/dev/null 2>&1 && ${SUDO} chattr -R -i "${LEGACY_PR_DIR}" 2>/dev/null || true

  ${SUDO} chown -R webhook:webhook "${INSTANCE_DIR}" 2>/dev/null || true
  ${SUDO} chmod -R u+rwX,g+rwX "${INSTANCE_DIR}" 2>/dev/null || true
  ${SUDO} chown -R webhook:webhook "${LEGACY_PR_DIR}" 2>/dev/null || true
  ${SUDO} chmod -R u+rwX,g+rwX "${LEGACY_PR_DIR}" 2>/dev/null || true

  ${RM} -rf --one-file-system -- "${INSTANCE_DIR}" || true
  ${RM} -rf --one-file-system -- "${LEGACY_PR_DIR}" || true
  ${RM} -rf -- "${LEGACY_META_DIR}" || true
  find "${PREVIEW_BASE}/logs" -maxdepth 1 -type f -name "pr-${PR_NUMBER}-*.log" -delete 2>/dev/null || true

  json_response "cleaned" "Preview resources cleaned up"
) 9>"${LOCK_FILE}"
