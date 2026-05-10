#!/usr/bin/env bash
set -Eeuo pipefail

MONOREPO_GIT_URL="${MONOREPO_GIT_URL:?missing}"
PREVIEW_BASE="${PREVIEW_BASE:-/var/lib/pr-previews}"
INSTANCES_DIR="${PREVIEW_BASE}/instances"
LOCK_DIR="${PREVIEW_BASE}/locks"
PORTS_FILE="${PREVIEW_BASE}/used-ports.txt"
TRAEFIK_CONFIG_DIR="${TRAEFIK_CONFIG_DIR:-/etc/traefik/dynamic}"
SYSTEMCTL_HELPER="${PR_PREVIEW_SYSTEMCTL:-preview-systemctl}"
: "${SUDO:=sudo}"

mkdir -p "${INSTANCES_DIR}" "${LOCK_DIR}" "${PREVIEW_BASE}/logs" "${TRAEFIK_CONFIG_DIR}"
touch "${PORTS_FILE}"

WORKER_MODE=0
if [ "${1:-}" = "--worker" ]; then
  WORKER_MODE=1
  INSTANCE_ID=${2:?missing instance id}
  if [[ ! "${INSTANCE_ID}" =~ ^pr-[0-9]+-[a-z0-9-]+$ ]]; then
    echo "Invalid preview instance id: ${INSTANCE_ID}" >&2
    exit 2
  fi

  INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_ID}"
  STATE_FILE="${INSTANCE_DIR}/state.json"
  if [ ! -f "${STATE_FILE}" ]; then
    echo "Missing preview state: ${STATE_FILE}" >&2
    exit 2
  fi

  PR_NUMBER="$(jq -r '.pr_number' "${STATE_FILE}")"
  WORKSPACE_LOWER="$(jq -r '.workspace' "${STATE_FILE}")"
  WORKSPACE="${WORKSPACE_LOWER}"
  BRANCH="$(jq -r '.branch' "${STATE_FILE}")"
  HEAD_SHA="$(jq -r '.requested_sha // ""' "${STATE_FILE}")"
else
  PR_NUMBER=${1:?missing PR number}
  WORKSPACE=${2:-Satchel}
  BRANCH=${3:?missing branch}
  HEAD_SHA=${4:-}
  WORKSPACE_LOWER="$(printf "%s" "${WORKSPACE}" | tr '[:upper:]' '[:lower:]')"
  INSTANCE_ID="pr-${PR_NUMBER}-${WORKSPACE_LOWER}"
  INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_ID}"
  STATE_FILE="${INSTANCE_DIR}/state.json"
fi

if [[ ! "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo '{"status":"error","message":"pr_number must be numeric"}'
  exit 1
fi

case "${WORKSPACE_LOWER}" in
  satchel) ;;
  *)
    echo '{"status":"error","message":"unsupported workspace"}'
    exit 1
    ;;
esac

if ! git check-ref-format --branch "${BRANCH}" >/dev/null 2>&1; then
  echo '{"status":"error","message":"invalid branch ref"}'
  exit 1
fi

if [ -n "${HEAD_SHA}" ] && [[ ! "${HEAD_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo '{"status":"error","message":"head_sha must be a full 40-character commit SHA"}'
  exit 1
fi

REPO_DIR="${INSTANCE_DIR}/repo"
DEPLOY_LOG="${INSTANCE_DIR}/deploy.log"
APP_LOG="${INSTANCE_DIR}/app.log"
LOCK_FILE="${LOCK_DIR}/${INSTANCE_ID}.lock"
PORT_LOCK_FILE="${LOCK_DIR}/ports.lock"
ROUTE_FILE="${TRAEFIK_CONFIG_DIR}/${INSTANCE_ID}.yml"
PREVIEW_HOST="${INSTANCE_ID}.preview.commongoodlt.dev"
PREVIEW_URL="https://${PREVIEW_HOST}"
LOGS_URL="${PREVIEW_URL}/logs/${INSTANCE_ID}"
STATUS_URL="${PREVIEW_URL}/status/${INSTANCE_ID}"
DEPLOYMENT_ID="${INSTANCE_ID}-$(date +%Y%m%d%H%M%S)"
if [ "${WORKER_MODE}" -eq 1 ]; then
  DEPLOYMENT_ID="$(jq -r '.deployment_id // empty' "${STATE_FILE}")"
  if [ -z "${DEPLOYMENT_ID}" ]; then
    DEPLOYMENT_ID="${INSTANCE_ID}-$(date +%Y%m%d%H%M%S)"
  fi
fi
PORT=""
RESOLVED_SHA=""

json_response() {
  local status=$1
  local message=$2
  jq -n \
    --arg status "${status}" \
    --arg message "${message}" \
    --arg preview_url "${PREVIEW_URL}" \
    --arg logs_url "${LOGS_URL}" \
    --arg status_url "${STATUS_URL}" \
    --arg deployment_id "${DEPLOYMENT_ID}" \
    --arg instance_id "${INSTANCE_ID}" \
    '{status:$status,message:$message,preview_url:$preview_url,logs_url:$logs_url,status_url:$status_url,deployment_id:$deployment_id,instance_id:$instance_id}'
}

write_state() {
  local status=$1
  local message=$2
  local port=${3:-}
  local resolved_sha=${4:-}
  local updated_at
  updated_at="$(date -Iseconds)"

  jq -n \
    --arg status "${status}" \
    --arg message "${message}" \
    --arg pr_number "${PR_NUMBER}" \
    --arg workspace "${WORKSPACE_LOWER}" \
    --arg branch "${BRANCH}" \
    --arg requested_sha "${HEAD_SHA}" \
    --arg resolved_sha "${resolved_sha}" \
    --arg preview_url "${PREVIEW_URL}" \
    --arg logs_url "${LOGS_URL}" \
    --arg status_url "${STATUS_URL}" \
    --arg deployment_id "${DEPLOYMENT_ID}" \
    --arg instance_id "${INSTANCE_ID}" \
    --arg repo_dir "${REPO_DIR}" \
    --arg deploy_log "${DEPLOY_LOG}" \
    --arg app_log "${APP_LOG}" \
    --arg updated_at "${updated_at}" \
    --arg port "${port}" \
    '{
      status: $status,
      message: $message,
      pr_number: ($pr_number | tonumber),
      workspace: $workspace,
      branch: $branch,
      requested_sha: $requested_sha,
      resolved_sha: $resolved_sha,
      preview_url: $preview_url,
      logs_url: $logs_url,
      status_url: $status_url,
      deployment_id: $deployment_id,
      instance_id: $instance_id,
      repo_dir: $repo_dir,
      deploy_log: $deploy_log,
      app_log: $app_log,
      updated_at: $updated_at,
      port: (if $port == "" then null else ($port | tonumber) end)
    }' > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

current_port() {
  if [ -f "${STATE_FILE}" ]; then
    jq -r '.port // empty' "${STATE_FILE}" 2>/dev/null || true
  fi
}

route_to_status() {
  cat > "${ROUTE_FILE}.tmp" <<EOF
http:
  routers:
    ${INSTANCE_ID}:
      rule: "Host(\`${PREVIEW_HOST}\`) && !PathPrefix(\`/logs\`) && !PathPrefix(\`/status\`)"
      entryPoints: [ "web" ]
      service: deployment-status
      priority: 50
EOF
  mv "${ROUTE_FILE}.tmp" "${ROUTE_FILE}"
  chmod 0644 "${ROUTE_FILE}"
}

route_to_app() {
  local port=$1
  cat > "${ROUTE_FILE}.tmp" <<EOF
http:
  routers:
    ${INSTANCE_ID}:
      rule: "Host(\`${PREVIEW_HOST}\`) && !PathPrefix(\`/logs\`) && !PathPrefix(\`/status\`)"
      entryPoints: [ "web" ]
      service: ${INSTANCE_ID}
      priority: 50
  services:
    ${INSTANCE_ID}:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${port}"
EOF
  mv "${ROUTE_FILE}.tmp" "${ROUTE_FILE}"
  chmod 0644 "${ROUTE_FILE}"
}

port_in_use() {
  local port=$1
  ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN
}

allocate_port() {
  local preferred=$((5000 + PR_NUMBER))
  if [ "${preferred}" -gt 6000 ]; then
    preferred=$((5000 + (PR_NUMBER % 1000)))
  fi

  (
    flock -x 9

    local existing_port=""
    existing_port="$(current_port)"
    if [[ "${existing_port}" =~ ^[0-9]+$ ]] && ! port_in_use "${existing_port}"; then
      grep -v "^${INSTANCE_ID} " "${PORTS_FILE}" > "${PORTS_FILE}.tmp" || true
      printf "%s %s\n" "${INSTANCE_ID}" "${existing_port}" >> "${PORTS_FILE}.tmp"
      mv "${PORTS_FILE}.tmp" "${PORTS_FILE}"
      printf "%s\n" "${existing_port}"
      exit 0
    fi

    for port in "${preferred}" $(seq 5000 6000); do
      if grep -q " ${port}$" "${PORTS_FILE}" 2>/dev/null && ! grep -q "^${INSTANCE_ID} ${port}$" "${PORTS_FILE}" 2>/dev/null; then
        continue
      fi
      if port_in_use "${port}"; then
        continue
      fi
      grep -v "^${INSTANCE_ID} " "${PORTS_FILE}" > "${PORTS_FILE}.tmp" || true
      printf "%s %s\n" "${INSTANCE_ID}" "${port}" >> "${PORTS_FILE}.tmp"
      mv "${PORTS_FILE}.tmp" "${PORTS_FILE}"
      printf "%s\n" "${port}"
      exit 0
    done

    echo "No preview ports available" >&2
    exit 1
  ) 9>"${PORT_LOCK_FILE}"
}

release_port() {
  (
    flock -x 9
    grep -v "^${INSTANCE_ID} " "${PORTS_FILE}" > "${PORTS_FILE}.tmp" || true
    mv "${PORTS_FILE}.tmp" "${PORTS_FILE}"
  ) 9>"${PORT_LOCK_FILE}"
}

stop_service() {
  ${SUDO} "${SYSTEMCTL_HELPER}" stop "${INSTANCE_ID}" >/dev/null 2>&1 || true
  ${SUDO} "${SYSTEMCTL_HELPER}" reset-failed "${INSTANCE_ID}" >/dev/null 2>&1 || true
}

wait_for_local_ready() {
  local port=$1
  for _ in $(seq 1 180); do
    if curl -fsS "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

public_health_check() {
  local tmp_body="${INSTANCE_DIR}/public-health.log"
  local http_code

  set +e
  http_code="$(curl -k -sS -o "${tmp_body}" -w "%{http_code}" "${PREVIEW_URL}/src/ajax.php")"
  local curl_exit=$?
  set -e

  if [ "${curl_exit}" -ne 0 ]; then
    echo "Public health check curl failed with exit code ${curl_exit}"
    return 1
  fi

  echo "Public health check HTTP code: ${http_code}"
  case "${http_code}" in
    200|204|301|302|304|401|403|404)
      ;;
    *)
      return 1
      ;;
  esac

  if grep -Eiq "Proxy error: Could not proxy request|ECONNREFUSED|Bad Gateway" "${tmp_body}" 2>/dev/null; then
    echo "Public health response contains proxy failure text"
    return 1
  fi
}

accept_deploy() {
  ${SUDO} "${SYSTEMCTL_HELPER}" stop-deploy "${INSTANCE_ID}" >/dev/null 2>&1 || true
  stop_service

  (
    flock -x 9
    mkdir -p "${INSTANCE_DIR}"
    touch "${DEPLOY_LOG}" "${APP_LOG}"
    local existing_port
    existing_port="$(current_port)"
    write_state "queued" "Deployment accepted and queued on preview host" "${existing_port}" ""
    route_to_status
  ) 9>"${LOCK_FILE}"

  ${SUDO} "${SYSTEMCTL_HELPER}" restart-deploy "${INSTANCE_ID}"
  json_response "queued" "Deployment accepted and queued on preview host"
}

deploy_worker() {
  (
    flock -x 9
    : > "${DEPLOY_LOG}"
    : > "${APP_LOG}"

    unexpected_failure() {
      local exit_code=$?
      route_to_status || true
      write_state "failed" "Deployment failed unexpectedly; see deploy logs" "${PORT}" "${RESOLVED_SHA}" || true
      exit "${exit_code}"
    }
    trap unexpected_failure ERR

    {
      echo "=== Starting deployment for ${INSTANCE_ID} ==="
      echo "Branch: ${BRANCH}"
      [ -n "${HEAD_SHA}" ] && echo "Requested SHA: ${HEAD_SHA}"
      echo "Deployment ID: ${DEPLOYMENT_ID}"
      echo "Time: $(date -Iseconds)"

      route_to_status
      stop_service

      echo
      echo "Allocating preview port..."
      PORT="$(allocate_port)"
      echo "Assigned port: ${PORT}"
      write_state "deploying" "Cloning repository" "${PORT}" ""

      echo
      echo "Preparing repository..."
      rm -rf --one-file-system -- "${REPO_DIR}"
      git clone --depth 1 --branch "${BRANCH}" "${MONOREPO_GIT_URL}" "${REPO_DIR}"
      cd "${REPO_DIR}"

      RESOLVED_SHA="$(git rev-parse HEAD)"
      echo "Resolved SHA: ${RESOLVED_SHA}"
      if [ -n "${HEAD_SHA}" ] && [ "${RESOLVED_SHA}" != "${HEAD_SHA}" ]; then
        write_state "failed" "Fetched branch SHA did not match requested GitHub head SHA" "${PORT}" "${RESOLVED_SHA}"
        release_port
        echo "ERROR: expected ${HEAD_SHA}, got ${RESOLVED_SHA}"
        exit 1
      fi

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
      echo "Installing dependencies with persistent pnpm store..."
      export HOME="${PR_PREVIEW_PNPM_HOME:-/var/lib/pr-previews/.pnpm-home}"
      export PNPM_HOME="${PR_PREVIEW_PNPM_HOME:-/var/lib/pr-previews/.pnpm-home}"
      export XDG_CACHE_HOME="${PR_PREVIEW_NODE_CACHE_DIR:-/var/lib/pr-previews/.cache}"
      export npm_config_cache="${PR_PREVIEW_NPM_CACHE_DIR:-/var/lib/pr-previews/.npm-cache}"
      export YARN_CACHE_FOLDER="${PR_PREVIEW_YARN_CACHE_DIR:-/var/lib/pr-previews/.yarn-cache}"
      export TURBO_CACHE_DIR="${TURBO_CACHE_DIR:-/var/lib/pr-previews/.turbo-cache}"
      PNPM_STORE_DIR="${PR_PREVIEW_PNPM_STORE_DIR:-/var/lib/pr-previews/.pnpm-store}"
      mkdir -p "$HOME" "$PNPM_HOME" "$XDG_CACHE_HOME" "$npm_config_cache" "$YARN_CACHE_FOLDER" "$TURBO_CACHE_DIR" "$PNPM_STORE_DIR"
      PNPM_DEBUG_LEVEL=debug pnpm -r install --reporter=append-only --frozen-lockfile --prefer-offline --store-dir "$PNPM_STORE_DIR"

      echo
      echo "Initializing Satchel environment..."
      write_state "deploying" "Initializing Satchel environment" "${PORT}" "${RESOLVED_SHA}"
      pnpm run satchel init -v --no-ssh --compose-project-name "${INSTANCE_ID}"

      echo
      echo "Starting systemd service pr-preview@${INSTANCE_ID}.service..."
      write_state "starting" "Starting preview service" "${PORT}" "${RESOLVED_SHA}"
      ${SUDO} "${SYSTEMCTL_HELPER}" restart "${INSTANCE_ID}"

      echo "Waiting for local readiness on 127.0.0.1:${PORT}..."
      if ! wait_for_local_ready "${PORT}"; then
        write_state "failed" "Preview service did not become ready on its local port" "${PORT}" "${RESOLVED_SHA}"
        echo "ERROR: preview service did not become ready on local port"
        exit 1
      fi

      echo "Switching Traefik route to app..."
      route_to_app "${PORT}"

      echo "Running public health check..."
      if ! public_health_check; then
        route_to_status
        write_state "failed" "Public preview health check failed after route switch" "${PORT}" "${RESOLVED_SHA}"
        echo "ERROR: public preview health check failed"
        exit 1
      fi

      write_state "ready" "Preview is ready" "${PORT}" "${RESOLVED_SHA}"
      echo
      echo "=== Deployment complete ==="
      echo "Preview: ${PREVIEW_URL}"
      echo "Logs: ${LOGS_URL}"
      echo "Time: $(date -Iseconds)"
    } >> "${DEPLOY_LOG}" 2>&1
  ) 9>"${LOCK_FILE}"
}

if [ "${WORKER_MODE}" -eq 1 ]; then
  deploy_worker
else
  accept_deploy
fi
