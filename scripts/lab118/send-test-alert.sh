#!/usr/bin/env bash
# Sends (open) or resolves (close) a test alert through the full pipeline:
# Alerta API -> alerta-apprise-forwarder -> Apprise -> ntfy -> ntfy.sh -> phone.
# Runs ON lab118-services; the API key is read there and never printed.
#
#   ssh lab118-services 'sudo bash -s -- open'  < scripts/lab118/send-test-alert.sh
#   ssh lab118-services 'sudo bash -s -- close' < scripts/lab118/send-test-alert.sh
set -euo pipefail

case "${1:-}" in
  open) severity=major; text="lab118-services end-to-end test (open)" ;;
  close) severity=normal; text="lab118-services end-to-end test (resolved)" ;;
  *) echo "usage: send-test-alert.sh open|close" >&2; exit 1 ;;
esac

key_file=/run/doppler-secrets/alerta/api-key
payload="$(printf '{"resource":"lab118-services","event":"EndToEndTest","environment":"Homelab","severity":"%s","service":["lab118"],"text":"%s","origin":"send-test-alert.sh"}' "$severity" "$text")"

curl -fsS -o /dev/null -w 'Alerta API: HTTP %{http_code}\n' \
  -H "Authorization: Key $(<"$key_file")" \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  http://127.0.0.1:5000/alert

echo "Sent severity=${severity}. The forwarder polls every 15s; watch: journalctl -u alerta-apprise-forwarder -f"
