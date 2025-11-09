#!@bash@
set -euo pipefail

PR_NUMBER=$1

PREVIEW_BASE="/var/lib/pr-previews"
PORTS_FILE="${PREVIEW_BASE}/used-ports.txt"
TRAEFIK_CONFIG_DIR="/etc/traefik/dynamic"

echo "=== Cleaning up PR #${PR_NUMBER} ==="

PORT_FILE="${PREVIEW_BASE}/pr-${PR_NUMBER}/port"
if [ -f "$PORT_FILE" ]; then
    PORT=$(@cat@ "$PORT_FILE")
    echo "Found port: ${PORT}"
    
    @grep@ -v "^${PORT}$" "${PORTS_FILE}" > "${PORTS_FILE}.tmp" || true
    @mv@ "${PORTS_FILE}.tmp" "${PORTS_FILE}"
fi

PR_DIR="${PREVIEW_BASE}/monorepo-pr-${PR_NUMBER}"
if [ -d "$PR_DIR" ]; then
    echo "Stopping Satchel..."
    cd "$PR_DIR"
    @pnpm@ run satchel stop || true
fi

echo "Removing PR directory..."
@rm@ -rf "$PR_DIR"
@rm@ -rf "${PREVIEW_BASE}/pr-${PR_NUMBER}"

echo "Removing Traefik configuration..."
@rm@ -f "${TRAEFIK_CONFIG_DIR}/pr-${PR_NUMBER}-"*.yml

@rm@ -f "${PREVIEW_BASE}/logs/pr-${PR_NUMBER}.log"

echo "Cleanup complete for PR #${PR_NUMBER}"

cat <<JSON
{
    "status": "success",
    "pr_number": ${PR_NUMBER},
    "message": "Preview environment cleaned up"
}
JSON