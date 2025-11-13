#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER=$1
WORKSPACE=$2  # Satchel - Cureum - Components
BRANCH=$3
# TODO: in the future, we will also support running against the staging backend, or not fetching if not needed

MONOREPO_GIT_URL="${MONOREPO_GIT_URL:?missing}"
PREVIEW_BASE="/var/lib/pr-previews"
PORTS_FILE="${PREVIEW_BASE}/used-ports.txt"
TRAEFIK_CONFIG_DIR="/etc/traefik/dynamic"

WORKSPACE_LOWER="$(printf "%s" "$WORKSPACE" | tr '[:upper:]' '[:lower:]')"
PR_DIR="${PREVIEW_BASE}/monorepo-pr-${PR_NUMBER}"
LOG_FILE="${PREVIEW_BASE}/logs/pr-${PR_NUMBER}-${WORKSPACE_LOWER}.log"
: > "$LOG_FILE"

# Create necessary directories
mkdir -p "${PREVIEW_BASE}/logs"
mkdir -p "${TRAEFIK_CONFIG_DIR}"
touch "${PORTS_FILE}"

# Clear previous log
: > "$LOG_FILE"

PREVIEW_HOST="pr-${PR_NUMBER}-${WORKSPACE_LOWER}.preview.commongoodlt.dev"
PREVIEW_URL="https://${PREVIEW_HOST}"

# Immediate JSON response for webhook
cat <<JSON
{
  "status": "deploying",
  "message": "Deployment started - visit URL to see live progress",
  "preview_url": "${PREVIEW_URL}",
  "pr_number": ${PR_NUMBER},
  "workspace": "${WORKSPACE}"
}
JSON

PR_FILE_STATUS="${TRAEFIK_CONFIG_DIR}/pr-${PR_NUMBER}-${WORKSPACE_LOWER}.yml"

cat > "${PR_FILE_STATUS}.tmp" <<EOF
http:
  routers:
    pr-${PR_NUMBER}-${WORKSPACE_LOWER}:
      rule: "Host(\`${PREVIEW_HOST}\`) && !PathPrefix(\`/logs\`)"
      entryPoints: [ "web" ]
      service: deployment-status
      priority: 50
EOF
mv "${PR_FILE_STATUS}.tmp" "${PR_FILE_STATUS}"

# Background the real work; all output → log
(
  exec 1>>"$LOG_FILE" 2>&1

  echo "=== Starting Deployment for PR #${PR_NUMBER} ==="
  echo "Branch: $BRANCH"
  echo "Time: $(date)"
  echo
  which ssh; ssh -V
  which rsync; rsync --version

  # Choose a port (5000 + PR) with fallback scan
  PORT=$((5000 + PR_NUMBER))
  if grep -q "^${PORT}$" "${PORTS_FILE}"; then
    echo "Port ${PORT} already in use, finding alternative..."
    for test_port in $(seq 5000 6000); do
      if ! grep -q "^${test_port}$" "${PORTS_FILE}"; then
        PORT=${test_port}
        break
      fi
    done
  fi

  echo "Assigned port: ${PORT}"
  echo "${PORT}" >> "${PORTS_FILE}"

  mkdir -p "${PREVIEW_BASE}/pr-${PR_NUMBER}"
  echo "${PORT}" > "${PREVIEW_BASE}/pr-${PR_NUMBER}/port"

  echo
  echo "Cloning repository..."
  rm -rf "$PR_DIR"
  git clone --depth 1 --branch "$BRANCH" "${MONOREPO_GIT_URL}" "$PR_DIR"
  cd "$PR_DIR"

  echo
  echo "Creating .npmrc for Font Awesome auth..."
  umask 077
  cat > .npmrc <<EOF
@fortawesome:registry=https://npm.fontawesome.com/
//npm.fontawesome.com/:_authToken=${NPM_TOKEN}
hoist=false
node-linker=hoisted
EOF

  echo
  echo "Installing dependencies (pnpm)…"
  export HOME="/tmp/pnpm-home-pr-${PR_NUMBER}"
  mkdir -p "$HOME"
  PNPM_DEBUG_LEVEL=debug pnpm -r install --reporter=append-only --frozen-lockfile

  echo
  echo "Initializing Satchel environment…"
  pnpm run satchel init -v --no-ssh --compose-project-name "pr-${PR_NUMBER}-${WORKSPACE_LOWER}"

  echo
  echo "Starting Satchel on port ${PORT}…"
  pnpm run satchel start --port "${PORT}" -v &

  echo
  echo "Waiting for app to listen on ${PORT}…"
  for i in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
      echo "App is up."
      break
    fi
    sleep 1
  done

  # Switch router to point to the app
  cat > "${PR_FILE_STATUS}.tmp" <<EOF
http:
  routers:
    pr-${PR_NUMBER}-${WORKSPACE_LOWER}:
      rule: "Host(\`${PREVIEW_HOST}\`) && !PathPrefix(\`/logs\`)"
      entryPoints: [ "web" ]
      service: pr-${PR_NUMBER}-${WORKSPACE_LOWER}
      priority: 50
  services:
    pr-${PR_NUMBER}-${WORKSPACE_LOWER}:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${PORT}"
EOF
  mv "${PR_FILE_STATUS}.tmp" "${PR_FILE_STATUS}"
  chmod 0644 "${PR_FILE_STATUS}"

  ########################################
  # Post-start health check + auto-restart
  ########################################

  health_check() {
    local url="${1}"
    local health_url="${url}/src/ajax.php"
    local tmp_body="/tmp/health-${PR_NUMBER}-${WORKSPACE_LOWER}.log"

    echo
    echo "Running post-start health check on ${health_url}…"

    # Don't let curl failures kill the script
    set +e
    local http_code
    http_code="$(curl -k -sS -o "${tmp_body}" -w "%{http_code}" "${health_url}")"
    local curl_exit=$?
    set -e

    if [ "${curl_exit}" -ne 0 ]; then
      echo "Health check curl failed with exit code ${curl_exit}"
      return 1
    fi

    echo "Health check HTTP code: ${http_code}"

    # Fail on 502 from Traefik / proxy
    if [ "${http_code}" = "502" ]; then
      echo "Got HTTP 502 from health endpoint."
      return 1
    fi

    # Look for proxy error text in the response body
    if grep -q "Proxy error: Could not proxy request" "${tmp_body}" 2>/dev/null; then
      echo "Detected proxy error text in health response."
      return 1
    fi

    if grep -q "ECONNREFUSED" "${tmp_body}" 2>/dev/null; then
      echo "Detected ECONNREFUSED in health response."
      return 1
    fi

    echo "Health check passed."
    return 0
  }

  # Try once, and if it's bad, restart Satchel once and re-check
  MAX_RESTARTS=1
  RESTART_COUNT=0

  if ! health_check "${PREVIEW_URL}"; then
    while [ "${RESTART_COUNT}" -lt "${MAX_RESTARTS}" ]; do
      RERESTART_IDX=$((RESTART_COUNT + 1))
      echo
      echo "Health check failed – restarting Satchel (attempt ${RERESTART_IDX}/${MAX_RESTARTS})…"

      set +e
      pnpm run satchel stop || true
      set -e

      pnpm run satchel start --port "${PORT}" -v &

      echo
      echo "Waiting for app to listen on ${PORT} after restart…"
      for i in $(seq 1 120); do
        if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
          echo "App is up after restart."
          break
        fi
        sleep 1
      done

      if health_check "${PREVIEW_URL}"; then
        echo "Health check passed after restart."
        break
      fi

      RESTART_COUNT=$((RESTART_COUNT + 1))
    done

    if [ "${RESTART_COUNT}" -ge "${MAX_RESTARTS}" ]; then
      echo "Health check still failing after ${MAX_RESTARTS} restart attempt(s). Leaving deployment as-is."
    fi
  fi

  echo
  echo "=== Deployment Complete ==="
  echo "Frontend: ${PREVIEW_URL}"
  echo "Port: ${PORT}"
  echo "Time: $(date)"

  echo "complete" > "${PREVIEW_BASE}/pr-${PR_NUMBER}/.deploy-status"
) &
