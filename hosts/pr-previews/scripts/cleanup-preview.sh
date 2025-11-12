#!/usr/bin/env bash
set -euo pipefail

: "${CAT:=cat}"
: "${RM:=rm}"
: "${GREP:=grep}"
: "${MV:=mv}"
: "${PNPM:=pnpm}"
: "${MKTEMP:=mktemp}"

PR_NUMBER=${1:?missing PR number}

PREVIEW_BASE="/var/lib/pr-previews"
PR_META_DIR="${PREVIEW_BASE}/pr-${PR_NUMBER}"
PR_DIR="${PREVIEW_BASE}/monorepo-pr-${PR_NUMBER}"
PORTS_FILE="${PREVIEW_BASE}/used-ports.txt"
TRAEFIK_CONFIG_DIR="/etc/traefik/dynamic"

echo "=== Cleaning up PR #${PR_NUMBER} ==="

# Read saved port (if any)
PORT=""
PORT_FILE="${PR_META_DIR}/port"
if [ -f "${PORT_FILE}" ]; then
  PORT="$(${CAT} "${PORT_FILE}" 2>/dev/null || true)"
  [ -n "${PORT}" ] && echo "Found port: ${PORT}"
fi

# 1) Best-effort app stop (if package scripts can do it)
if [ -d "${PR_DIR}" ]; then
  echo "Stopping app via pnpm (best-effort)..."
  ( cd "${PR_DIR}" && ${PNPM} run satchel stop ) || true
fi

# 2) Kill anything listening on the saved port (no deploy changes needed)
if [ -n "${PORT}" ]; then
  echo "Ensuring nothing is listening on :${PORT}..."
  if command -v fuser >/dev/null 2>&1; then
    fuser -k -TERM -n tcp "${PORT}" 2>/dev/null || true
    sleep 2
    fuser -k -KILL -n tcp "${PORT}" 2>/dev/null || true
  elif command -v ss >/dev/null 2>&1; then
    PIDS="$(ss -lptn "sport = :${PORT}" 2>/dev/null | awk -F',' '/users:/ { sub(/.*pid=/,"",$2); sub(/,.*/,"",$2); print $2 }' | sort -u)"
    [ -n "${PIDS}" ] && { echo "Killing PIDs on ${PORT}: ${PIDS}"; kill -TERM ${PIDS} 2>/dev/null || true; sleep 2; kill -KILL ${PIDS} 2>/dev/null || true; }
  fi
fi

# 3) If anything still has files open under the PR dir, kill those (fallback)
if [ -d "${PR_DIR}" ] && command -v lsof >/dev/null 2>&1; then
  echo "Killing processes with open files in ${PR_DIR} (best-effort)..."
  PIDS="$(lsof -t +D "${PR_DIR}" 2>/dev/null | sort -u || true)"
  [ -n "${PIDS}" ] && { kill -TERM ${PIDS} 2>/dev/null || true; sleep 2; kill -KILL ${PIDS} 2>/dev/null || true; }
fi

# 4) Fix ownership/permissions so rm won't choke on write-protect bits
if [ -d "${PR_DIR}" ]; then
  echo "Relaxing ownership/perms in ${PR_DIR}..."
  chown -R webhook:webhook "${PR_DIR}" 2>/dev/null || true
  chmod -R u+rwX "${PR_DIR}" 2>/dev/null || true
fi

# 5) Remove directories (retry once if needed)
echo "Removing PR directory and metadata…"
if [ -d "${PR_DIR}" ]; then
  ${RM} -rf --one-file-system -- "${PR_DIR}" || { sleep 1; ${RM} -rf --one-file-system -- "${PR_DIR}" || true; }
fi
${RM} -rf -- "${PR_META_DIR}" || true

# 6) Remove Traefik dynamic config (Traefik file provider is watch=true)
echo "Removing Traefik configuration…"
${RM} -f -- "${TRAEFIK_CONFIG_DIR}/pr-${PR_NUMBER}-"*.yml || true

# 7) Remove PR log (if you keep per-PR logs)
echo "Removing PR log…"
${RM} -f -- "${PREVIEW_BASE}/logs/pr-${PR_NUMBER}.log" || true

# 8) Free the port from the tracked list
if [ -n "${PORT}" ] && [ -f "${PORTS_FILE}" ]; then
  TMP="$(${MKTEMP})"
  ${GREP} -vxF "${PORT}" "${PORTS_FILE}" > "${TMP}" || true
  ${MV} "${TMP}" "${PORTS_FILE}"
  echo "Freed port ${PORT}"
fi

echo "Cleanup complete for PR #${PR_NUMBER}"
cat <<JSON
{
  "status": "success",
  "pr_number": ${PR_NUMBER},
  "message": "Preview environment cleaned up"
}
JSON
