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

# Immediate JSON response for webhook
cat <<JSON
{
  "status": "deploying",
  "message": "Deployment started - visit URL to see live progress",
  "preview_url": "https://pr-${PR_NUMBER}-${WORKSPACE_LOWER}.preview.commongoodlt.dev",
  "pr_number": ${PR_NUMBER},
  "workspace": "${WORKSPACE}"
}
JSON


PR_FILE_STATUS="${TRAEFIK_CONFIG_DIR}/pr-${PR_NUMBER}-${WORKSPACE_LOWER}.yml"

cat > "${PR_FILE_STATUS}.tmp" <<EOF
http:
  routers:
    pr-${PR_NUMBER}-${WORKSPACE_LOWER}:
      rule: "Host(\`pr-${PR_NUMBER}-${WORKSPACE_LOWER}.preview.commongoodlt.dev\`)"
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
  # Use the NPM_TOKEN exported by the wrapper; keep perms tight and clean it up later
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
  pnpm install

  # Immediately shred .npmrc so the token doesn’t linger on disk
  shred -u .npmrc || rm -f .npmrc

  echo
  echo "Initializing Satchel environment…"
  pnpm run satchel init

  echo
  echo "Starting Satchel on port ${PORT}…"
  pnpm run satchel start --port "${PORT}" &

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
      rule: "Host(\`pr-${PR_NUMBER}-${WORKSPACE_LOWER}.preview.commongoodlt.dev\`)"
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

    echo
    echo "=== Deployment Complete ==="
    echo "Frontend: https://pr-${PR_NUMBER}-${WORKSPACE_LOWER}.preview.commongoodlt.dev"
    echo "Port: ${PORT}"
    echo "Time: $(date)"

    echo "complete" > "${PREVIEW_BASE}/pr-${PR_NUMBER}/.deploy-status"
) &
