#!/usr/bin/env bash
# Sends (open) or resolves (close) a test alert through the full pipeline:
# Alerta API -> push plugin's kick -> alerta-apprise-forwarder -> Apprise ->
# ntfy -> ntfy.sh -> phone, and says how long the forwarder took to send it.
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

start=$(date +%s.%N)
id=$(curl -fsS \
  -H "Authorization: Key $(<"$key_file")" \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  http://127.0.0.1:5000/alert | jq -r .id)
echo "Alerta took it as $id (severity=${severity})."

# Alerta's push plugin kicks the forwarder, which logs "sent <id>: <title>"
# once Apprise has it. The phone follows within a second or two.
for _ in {1..40}; do
  if journalctl -u alerta-apprise-forwarder --since "@${start%.*}" --no-pager -o cat | grep "^sent $id:" >/dev/null; then
    awk -v now="$(date +%s.%N)" -v start="$start" \
      'BEGIN { printf "The forwarder sent it to Apprise %.1f s after it was posted.\n", now - start }'
    exit 0
  fi
  sleep 0.25
done
echo "The forwarder hasn't sent it after 10 s. Look at: journalctl -u alerta-apprise-forwarder -u alerta -n 30" >&2
exit 1
