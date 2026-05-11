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
TF_BACKEND_CONFIG="${STATE_DIR}/backend.hcl"
EXTRA_FILES_DIR="${STATE_DIR}/extra-files"
AGE_KEY_PATH="${SOPS_AGE_KEY_PATH:-$HOME/.config/sops/age/keys.txt}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${SSH_PRIVATE_KEY_PATH}.pub}"
SECRETS_FILE="${NIXCONFIG_SECRETS_FILE:-${REPO_ROOT}/secrets/secrets.yaml}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-nix-terraform-state}"
TF_STATE_ENDPOINT="${TF_STATE_ENDPOINT:-https://fe5019fb2375a36bcf9aa82e5efc3a35.r2.cloudflarestorage.com}"
TF_STATE_KEY_PREFIX="${TF_STATE_KEY_PREFIX:-hosts}"
TF_STATE_REGION="${TF_STATE_REGION:-auto}"
TF_STATE_R2_ACCESS_KEY_PATH="${TF_STATE_R2_ACCESS_KEY_PATH:-[\"terraform\"][\"cloudflare_r2\"][\"aws_access_key_id\"]}"
TF_STATE_R2_SECRET_KEY_PATH="${TF_STATE_R2_SECRET_KEY_PATH:-[\"terraform\"][\"cloudflare_r2\"][\"aws_secret_access_key\"]}"

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

load_terraform_backend_credentials() {
  local access_key_id
  local secret_access_key

  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi

  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Missing secrets file: $SECRETS_FILE" >&2
    echo "Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or NIXCONFIG_SECRETS_FILE." >&2
    exit 1
  fi

  if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$AGE_KEY_PATH" ]]; then
    export SOPS_AGE_KEY_FILE="$AGE_KEY_PATH"
  fi

  if ! access_key_id="$(sops -d --extract "$TF_STATE_R2_ACCESS_KEY_PATH" "$SECRETS_FILE")"; then
    echo "Failed to decrypt Terraform R2 access key from ${SECRETS_FILE} at ${TF_STATE_R2_ACCESS_KEY_PATH}." >&2
    echo "Set SOPS_AGE_KEY_PATH or SOPS_AGE_KEY_FILE to the age identity that can decrypt the repo secrets." >&2
    exit 1
  fi

  if ! secret_access_key="$(sops -d --extract "$TF_STATE_R2_SECRET_KEY_PATH" "$SECRETS_FILE")"; then
    echo "Failed to decrypt Terraform R2 secret key from ${SECRETS_FILE} at ${TF_STATE_R2_SECRET_KEY_PATH}." >&2
    echo "Set SOPS_AGE_KEY_PATH or SOPS_AGE_KEY_FILE to the age identity that can decrypt the repo secrets." >&2
    exit 1
  fi

  export AWS_ACCESS_KEY_ID="$access_key_id"
  export AWS_SECRET_ACCESS_KEY="$secret_access_key"
}

write_terraform_backend_config() {
  cat > "$TF_BACKEND_CONFIG" <<EOF
bucket = "${TF_STATE_BUCKET}"
key = "${TF_STATE_KEY_PREFIX}/${HOST_NAME}/terraform.tfstate"
region = "${TF_STATE_REGION}"
endpoints = {
  s3 = "${TF_STATE_ENDPOINT}"
}
use_lockfile = true
use_path_style = true
skip_credentials_validation = true
skip_metadata_api_check = true
skip_region_validation = true
skip_requesting_account_id = true
skip_s3_checksum = true
EOF
}

backup_local_state_before_adopt() {
  local suffix

  if [[ "$ACTION" != "adopt" || ! -f "${STATE_DIR}/terraform.tfstate" ]]; then
    return 0
  fi

  suffix="$(date -u +%Y%m%d%H%M%S)"
  mv "${STATE_DIR}/terraform.tfstate" "${STATE_DIR}/terraform.tfstate.pre-adopt-${suffix}"

  if [[ -f "${STATE_DIR}/terraform.tfstate.backup" ]]; then
    mv "${STATE_DIR}/terraform.tfstate.backup" "${STATE_DIR}/terraform.tfstate.backup.pre-adopt-${suffix}"
  fi

  echo "Backed up local Terraform state before adopt: ${STATE_DIR}/terraform.tfstate.pre-adopt-${suffix}"
}

load_terraform_backend_credentials
write_terraform_backend_config
backup_local_state_before_adopt

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

terraform_init_args=(
  -input=false
  -backend-config="$TF_BACKEND_CONFIG"
)

case "$ACTION" in
  migrate-state)
    terraform_init_args+=(-migrate-state -force-copy)
    ;;
  adopt|plan|provision|destroy)
    terraform_init_args+=(-reconfigure)
    ;;
esac

terraform -chdir="$STATE_DIR" init "${terraform_init_args[@]}" >/dev/null

if [[ "$ACTION" == "migrate-state" ]]; then
  echo "Migrated Terraform state for ${HOST_NAME} to ${TF_STATE_BUCKET}/${TF_STATE_KEY_PREFIX}/${HOST_NAME}/terraform.tfstate"
  exit 0
fi

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

proxmox_api_get() {
  local path="$1"
  local api_base
  local auth_header
  local curl_args=()

  if [[ -z "${PROXMOX_VE_ENDPOINT:-}" ]]; then
    echo "PROXMOX_VE_ENDPOINT is not set." >&2
    exit 1
  fi

  api_base="$(normalize_api_base "${PROXMOX_VE_ENDPOINT}")"
  auth_header="$(proxmox_auth_header)"

  if [[ "${PROXMOX_VE_INSECURE:-}" == "true" ]]; then
    curl_args+=(-k)
  fi

  curl -fsS "${curl_args[@]}" -H "$auth_header" "${api_base}${path}"
}

state_has_vm_resource() {
  terraform -chdir="$STATE_DIR" state list 2>/dev/null \
    | grep -qx "proxmox_virtual_environment_vm.${HOST_NAME}"
}

guard_against_duplicate_vm() {
  local existing_vms
  local existing_count

  if state_has_vm_resource; then
    return 0
  fi

  existing_vms="$(
    proxmox_api_get "/cluster/resources?type=vm" \
      | jq -r --arg name "$HOST_NAME" '
          .data[]?
          | select(.name == $name)
          | "\(.node)/\(.vmid) \(.status)"
        '
  )"

  if [[ -z "$existing_vms" ]]; then
    return 0
  fi

  existing_count="$(wc -l <<<"$existing_vms" | tr -d ' ')"
  {
    echo "Refusing to create duplicate Proxmox VM for host '${HOST_NAME}'."
    echo
    echo "Terraform state at ${STATE_DIR} does not manage proxmox_virtual_environment_vm.${HOST_NAME},"
    echo "but Proxmox already has ${existing_count} VM(s) named '${HOST_NAME}':"
    echo "$existing_vms"
    echo
    echo "Use shared Terraform state, or import the existing VM into this state before provisioning."
    echo "Example:"
    echo "  nix run .#adopt -- ${HOST_NAME} <node>/<vmid>"
  } >&2
  exit 1
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
  adopt)
    IMPORT_ID="${1:-}"
    if [[ -z "$IMPORT_ID" ]]; then
      echo "usage: nix run .#adopt -- ${HOST_NAME} <node>/<vmid>" >&2
      exit 1
    fi
    exec terraform -chdir="$STATE_DIR" import \
      -var-file="$TF_VARS_JSON" \
      "proxmox_virtual_environment_vm.${HOST_NAME}" \
      "$IMPORT_ID"
    ;;
  plan)
    guard_against_duplicate_vm
    exec terraform -chdir="$STATE_DIR" plan -input=false -var-file="$TF_VARS_JSON" "$@"
    ;;
  provision)
    HARDWARE_CONFIG="${REPO_ROOT}/hosts/${HOST_NAME}/hardware-configuration.nix"
    OUTPUTS_JSON="${STATE_DIR}/outputs.json"
    NODE_NAME=""
    VM_ID=""
    TARGET_USER=""
    DISCOVERED_IP=""

    guard_against_duplicate_vm

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
