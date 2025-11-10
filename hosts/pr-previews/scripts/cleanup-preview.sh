#!/usr/bin/env bash
set -euo pipefail

# Use tool paths from env (exported by the Nix wrapper), with safe fallbacks for manual runs
: "${BASH:=/usr/bin/env bash}"
: "${CAT:=cat}"
: "${RM:=rm}"
: "${GREP:=grep}"
: "${MV:=mv}"
: "${PNPM:=pnpm}"
: "${MKTEMP:=mktemp}"
: "${MKDIR:=mkdir}"

PR_NUMBER=${1:?missing PR number}

PREVIEW_BASE="/var/lib/pr-previews"
PORTS_FILE="${PREVIEW_BASE}/used-ports.txt"
TRAEFIK_CONFIG_DIR="/etc/traefik/dynamic"

echo "=== Cleaning up PR #${PR_NUMBER} ==="

# Read the assigned port (if tracked) BEFORE deleting dirs
PR_META_DIR="${PREVIEW_BASE}/pr-${PR_NUMBER}"
PORT_FILE="${PR_META_DIR}/port"
PORT=""
if [ -f "${PORT_FILE}" ]; then
  PORT="$(${CAT} "${PORT_FILE}" 2>/dev/null || true)"
  if [ -n "${PORT}" ]; then
    echo "Found port: ${PORT}"
  fi
fi

# Stop Satchel if repo still exists (best-effort)
PR_DIR="${PREVIEW_BASE}/monorepo-pr-${PR_NUMBER}"
if [ -d "${PR_DIR}" ]; then
  echo "Stopping Satchel..."
  ( cd "${PR_DIR}" && ${PNPM} run satchel stop ) || true
fi

echo "Removing PR directory and metadata…"
${RM} -rf "${PR_DIR}"
${RM} -rf "${PR_META_DIR}"

echo "Removing Traefik configuration…"
# Might have multiple workspaces; remove any that match this PR number
${RM} -f "${TRAEFIK_CONFIG_DIR}/pr-${PR_NUMBER}-"*.yml || true

echo "Removing PR log…"
${RM} -f "${PREVIEW_BASE}/logs/pr-${PR_NUMBER}.log" || true

# Free the port from the tracked list, if present
if [ -n "${PORT}" ] && [ -f "${PORTS_FILE}" ]; then
  TMP="$(${MKTEMP})"
  # Remove the exact matching line for the port
  ${GREP} -vxF "${PORT}" "${PORTS_FILE}" > "${TMP}" || true
  ${MV} "${TMP}" "${PORTS_FILE}"
  echo "Freed port ${PORT}"
fi

echo "Cleanup complete for PR #${PR_NUMBER}"

# JSON response for webhook callers
cat <<JSON
{
  "status": "success",
  "pr_number": ${PR_NUMBER},
  "message": "Preview environment cleaned up"
}
JSON