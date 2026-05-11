#!/usr/bin/env bash
set -euo pipefail

ACTION="${NIX_INFRA_ACTION:-}"
if [[ -z "$ACTION" ]]; then
  echo "NIX_INFRA_ACTION must be set by the flake app." >&2
  exit 1
fi

HOST_NAME="${1:-}"
if [[ -z "$HOST_NAME" ]]; then
  echo "usage: nix run .#${ACTION} -- <host>" >&2
  exit 1
fi
shift || true

case "$HOST_NAME" in
  dockhand)
    TERRANIX_CONFIG="${TERRANIX_CONFIG_DOCKHAND:?}"
    ;;
  pr-previews)
    TERRANIX_CONFIG="${TERRANIX_CONFIG_PR_PREVIEWS:?}"
    ;;
  uptime-kuma)
    TERRANIX_CONFIG="${TERRANIX_CONFIG_UPTIME_KUMA:?}"
    ;;
  *)
    echo "unknown host: $HOST_NAME" >&2
    exit 1
    ;;
esac

REPO_ROOT="${NIXCONFIG_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${REPO_ROOT}/.state/terraform/${HOST_NAME}"
TF_CONFIG_JSON="${STATE_DIR}/config.tf.json"
TF_VARS_JSON="${STATE_DIR}/terraform.tfvars.json"
EXTRA_FILES_DIR="${STATE_DIR}/extra-files"
AGE_KEY_PATH="${SOPS_AGE_KEY_PATH:-$HOME/.config/sops/age/keys.txt}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${SSH_PRIVATE_KEY_PATH}.pub}"

mkdir -p "$STATE_DIR"

if [[ ! -f "$SSH_PRIVATE_KEY_PATH" ]]; then
  echo "missing bootstrap private key: $SSH_PRIVATE_KEY_PATH" >&2
  exit 1
fi

if [[ ! -f "$SSH_PUBLIC_KEY_PATH" ]]; then
  ssh-keygen -y -f "$SSH_PRIVATE_KEY_PATH" > "$SSH_PUBLIC_KEY_PATH"
fi

BOOTSTRAP_PUBLIC_KEY="$(tr -d '\n' < "$SSH_PUBLIC_KEY_PATH")"

install -m 0644 "$TERRANIX_CONFIG" "$TF_CONFIG_JSON"

rm -rf "$EXTRA_FILES_DIR"
mkdir -p "$EXTRA_FILES_DIR"

if [[ -n "${AGE_KEY_PATH}" && -f "${AGE_KEY_PATH}" ]]; then
  mkdir -p "$EXTRA_FILES_DIR/home/justin/.config/sops/age"
  install -m 0400 "$AGE_KEY_PATH" "$EXTRA_FILES_DIR/home/justin/.config/sops/age/keys.txt"
fi

jq -n \
  --arg bootstrap_public_key "$BOOTSTRAP_PUBLIC_KEY" \
  '{
    bootstrap_public_key: $bootstrap_public_key
  }' > "$TF_VARS_JSON"

terraform -chdir="$STATE_DIR" init -input=false >/dev/null

normalize_api_base() {
  local endpoint="$1"
  endpoint="${endpoint%/}"
  if [[ "$endpoint" == */api2/json ]]; then
    printf '%s\n' "$endpoint"
  else
    printf '%s/api2/json\n' "$endpoint"
  fi
}

proxmox_auth_header() {
  if [[ -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    echo "PROXMOX_VE_API_TOKEN is not set." >&2
    exit 1
  fi

  if [[ "${PROXMOX_VE_API_TOKEN}" == PVEAPIToken=* ]]; then
    printf '%s\n' "Authorization: ${PROXMOX_VE_API_TOKEN}"
  else
    printf '%s\n' "Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}"
  fi
}

discover_vm_ip() {
  local node_name="$1"
  local vm_id="$2"
  local api_base
  local auth_header
  local curl_args=()
  local response
  local ip=""

  if [[ -z "${PROXMOX_VE_ENDPOINT:-}" ]]; then
    echo "PROXMOX_VE_ENDPOINT is not set." >&2
    exit 1
  fi

  api_base="$(normalize_api_base "${PROXMOX_VE_ENDPOINT}")"
  auth_header="$(proxmox_auth_header)"

  if [[ "${PROXMOX_VE_INSECURE:-}" == "true" ]]; then
    curl_args+=(-k)
  fi

  for _ in $(seq 1 60); do
    if response="$(curl -fsS "${curl_args[@]}" -H "$auth_header" \
      "${api_base}/nodes/${node_name}/qemu/${vm_id}/agent/network-get-interfaces" 2>/dev/null)"; then
      ip="$(
        jq -r '
          .data.result[]?
          | select(.name != "lo")
          | .["ip-addresses"][]?
          | select(."ip-address-type" == "ipv4")
          | .["ip-address"]
          | select(startswith("127.") | not)
          | select(startswith("169.254.") | not)
        ' <<<"$response" | head -n 1
      )"
      if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return 0
      fi
    fi
    sleep 5
  done

  echo "Timed out waiting for DHCP IP from the Proxmox guest agent for VM ${vm_id} on ${node_name}." >&2
  return 1
}

run_nixos_anywhere() {
  local host_name="$1"
  local target_user="$2"
  local target_ip="$3"
  local hardware_config="$4"

  nixos-anywhere \
    --flake "${REPO_ROOT}#${host_name}" \
    --target-host "${target_user}@${target_ip}" \
    -i "${SSH_PRIVATE_KEY_PATH}" \
    --generate-hardware-config nixos-generate-config "${hardware_config}" \
    --extra-files "${EXTRA_FILES_DIR}"
}

case "$ACTION" in
  plan)
    exec terraform -chdir="$STATE_DIR" plan -input=false -var-file="$TF_VARS_JSON" "$@"
    ;;
  provision)
    HARDWARE_CONFIG="${REPO_ROOT}/hosts/${HOST_NAME}/hardware-configuration.nix"
    OUTPUTS_JSON="${STATE_DIR}/outputs.json"
    NODE_NAME=""
    VM_ID=""
    TARGET_USER=""
    DISCOVERED_IP=""

    rm -f "$HARDWARE_CONFIG"
    terraform -chdir="$STATE_DIR" apply -input=false -auto-approve -var-file="$TF_VARS_JSON" "$@"
    terraform -chdir="$STATE_DIR" output -json > "$OUTPUTS_JSON"

    NODE_NAME="$(jq -r '.node_name.value' "$OUTPUTS_JSON")"
    VM_ID="$(jq -r '.vm_id.value' "$OUTPUTS_JSON")"
    TARGET_USER="$(jq -r '.target_user.value' "$OUTPUTS_JSON")"

    DISCOVERED_IP="$(discover_vm_ip "$NODE_NAME" "$VM_ID")"
    echo "Discovered DHCP IP for ${HOST_NAME}: ${DISCOVERED_IP}"

    run_nixos_anywhere "$HOST_NAME" "$TARGET_USER" "$DISCOVERED_IP" "$HARDWARE_CONFIG"

    if [[ -f "$HARDWARE_CONFIG" ]]; then
      echo "Saved hardware configuration to $HARDWARE_CONFIG"
    else
      echo "nixos-anywhere finished but hardware configuration was not generated." >&2
    fi
    ;;
  destroy)
    exec terraform -chdir="$STATE_DIR" destroy -input=false -auto-approve -var-file="$TF_VARS_JSON" "$@"
    ;;
  *)
    echo "unsupported action: $ACTION" >&2
    exit 1
    ;;
esac
