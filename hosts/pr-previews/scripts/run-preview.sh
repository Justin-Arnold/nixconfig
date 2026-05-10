#!/usr/bin/env bash
set -euo pipefail

INSTANCE_ID=${1:?missing instance id}

PREVIEW_BASE="${PREVIEW_BASE:-/var/lib/pr-previews}"
INSTANCE_DIR="${PREVIEW_BASE}/instances/${INSTANCE_ID}"
STATE_FILE="${INSTANCE_DIR}/state.json"
APP_LOG="${INSTANCE_DIR}/app.log"

if [[ ! "${INSTANCE_ID}" =~ ^pr-[0-9]+-[a-z0-9-]+$ ]]; then
  echo "Invalid preview instance id: ${INSTANCE_ID}" >&2
  exit 2
fi

if [ ! -f "${STATE_FILE}" ]; then
  echo "Missing preview state: ${STATE_FILE}" >&2
  exit 2
fi

PORT="$(jq -r '.port // empty' "${STATE_FILE}")"
REPO_DIR="$(jq -r '.repo_dir // empty' "${STATE_FILE}")"

if [[ ! "${PORT}" =~ ^[0-9]+$ ]]; then
  echo "Invalid or missing port in ${STATE_FILE}" >&2
  exit 2
fi

if [ -z "${REPO_DIR}" ] || [ ! -d "${REPO_DIR}" ]; then
  echo "Invalid or missing repo_dir in ${STATE_FILE}" >&2
  exit 2
fi

export HOME="${PR_PREVIEW_PNPM_HOME:-/var/lib/pr-previews/.pnpm-home}"
export PNPM_HOME="${PR_PREVIEW_PNPM_HOME:-/var/lib/pr-previews/.pnpm-home}"
export XDG_CACHE_HOME="${PR_PREVIEW_NODE_CACHE_DIR:-/var/lib/pr-previews/.cache}"
export npm_config_cache="${PR_PREVIEW_NPM_CACHE_DIR:-/var/lib/pr-previews/.npm-cache}"
export YARN_CACHE_FOLDER="${PR_PREVIEW_YARN_CACHE_DIR:-/var/lib/pr-previews/.yarn-cache}"
export TURBO_CACHE_DIR="${TURBO_CACHE_DIR:-/var/lib/pr-previews/.turbo-cache}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"
export COMPOSE_DOCKER_CLI_BUILD="${COMPOSE_DOCKER_CLI_BUILD:-1}"

mkdir -p "$HOME" "$PNPM_HOME" "$XDG_CACHE_HOME" "$npm_config_cache" "$YARN_CACHE_FOLDER" "$TURBO_CACHE_DIR"
mkdir -p "$(dirname "${APP_LOG}")"
touch "${APP_LOG}"

cd "${REPO_DIR}"
exec pnpm run satchel start --port "${PORT}" -v
