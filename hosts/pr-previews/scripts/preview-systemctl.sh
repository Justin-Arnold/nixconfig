#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:?missing action}
INSTANCE_ID=${2:?missing instance id}

case "${ACTION}" in
  start|stop|restart|status|is-active|reset-failed)
    UNIT="pr-preview@${INSTANCE_ID}.service"
    SYSTEMD_ACTION="${ACTION}"
    ;;
  start-deploy)
    UNIT="pr-preview-deploy@${INSTANCE_ID}.service"
    SYSTEMD_ACTION="start"
    ;;
  stop-deploy)
    UNIT="pr-preview-deploy@${INSTANCE_ID}.service"
    SYSTEMD_ACTION="stop"
    ;;
  restart-deploy)
    UNIT="pr-preview-deploy@${INSTANCE_ID}.service"
    SYSTEMD_ACTION="restart"
    ;;
  status-deploy)
    UNIT="pr-preview-deploy@${INSTANCE_ID}.service"
    SYSTEMD_ACTION="status"
    ;;
  *)
    echo "Unsupported action: ${ACTION}" >&2
    exit 2
    ;;
esac

if [[ ! "${INSTANCE_ID}" =~ ^pr-[0-9]+-[a-z0-9-]+$ ]]; then
  echo "Invalid preview instance id: ${INSTANCE_ID}" >&2
  exit 2
fi

exec /run/current-system/sw/bin/systemctl "${SYSTEMD_ACTION}" "${UNIT}"
