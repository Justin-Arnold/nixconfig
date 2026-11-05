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

# Host list, platform, Terraform JSON and deploy target come from the flake
# (infra/terranix/default.nix), so hosts are not hardcoded here.
HOSTS_MANIFEST="${NIXCONFIG_INFRA_HOSTS:-}"
if [[ -z "$HOSTS_MANIFEST" || ! -f "$HOSTS_MANIFEST" ]]; then
  echo "NIXCONFIG_INFRA_HOSTS must point at the host manifest built by the flake app." >&2
  exit 1
fi

if ! jq -e --arg host "$HOST_NAME" 'has($host)' "$HOSTS_MANIFEST" >/dev/null; then
  echo "unknown host: $HOST_NAME" >&2
  echo "known hosts: $(jq -r 'keys | join(", ")' "$HOSTS_MANIFEST")" >&2
  exit 1
fi

host_field() {
  jq -r --arg host "$HOST_NAME" --arg field "$1" '.[$host][$field] // empty' "$HOSTS_MANIFEST"
}

HOST_PLATFORM="$(host_field platform)"
TERRANIX_CONFIG="$(host_field terraformConfig)"

REPO_ROOT="${NIXCONFIG_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${REPO_ROOT}/.state/terraform/${HOST_NAME}"
TF_CONFIG_JSON="${STATE_DIR}/config.tf.json"
TF_VARS_JSON="${STATE_DIR}/terraform.tfvars.json"
TF_BACKEND_CONFIG="${STATE_DIR}/backend.hcl"
EXTRA_FILES_DIR="${STATE_DIR}/extra-files"
AGE_KEY_PATH="${SOPS_AGE_KEY_PATH:-$HOME/.config/sops/age/keys.txt}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${SSH_PRIVATE_KEY_PATH}.pub}"
SWITCH_SSH_PRIVATE_KEY_PATH="${SWITCH_SSH_PRIVATE_KEY_PATH:-}"
SWITCH_USER="${SWITCH_USER:-justin}"
SECRETS_FILE="${NIXCONFIG_SECRETS_FILE:-${REPO_ROOT}/secrets/secrets.yaml}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-nix-terraform-state}"
TF_STATE_ENDPOINT="${TF_STATE_ENDPOINT:-https://fe5019fb2375a36bcf9aa82e5efc3a35.r2.cloudflarestorage.com}"
TF_STATE_KEY_PREFIX="${TF_STATE_KEY_PREFIX:-hosts}"
TF_STATE_REGION="${TF_STATE_REGION:-auto}"
TF_STATE_R2_ACCESS_KEY_PATH="${TF_STATE_R2_ACCESS_KEY_PATH:-[\"terraform\"][\"cloudflare_r2\"][\"aws_access_key_id\"]}"
TF_STATE_R2_SECRET_KEY_PATH="${TF_STATE_R2_SECRET_KEY_PATH:-[\"terraform\"][\"cloudflare_r2\"][\"aws_secret_access_key\"]}"

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

run_nixos_switch() {
  local host_name="$1"
  local target_user="$2"
  local target_ip="$3"
  local nixos_rebuild_cmd=(nixos-rebuild)

  if [[ -n "$SWITCH_SSH_PRIVATE_KEY_PATH" ]]; then
    nixos_rebuild_cmd=(
      env
      "NIX_SSHOPTS=-o IdentitiesOnly=yes -o IdentityFile=${SWITCH_SSH_PRIVATE_KEY_PATH}"
      nixos-rebuild
    )
  fi

  "${nixos_rebuild_cmd[@]}" switch \
    --flake "${REPO_ROOT}#${host_name}" \
    --target-host "${target_user}@${target_ip}" \
    --build-host "${target_user}@${target_ip}" \
    --sudo \
    --use-substitutes \
    --no-reexec \
    --option accept-flake-config true
}

############################################################
## Contabo (cloud) hosts
############################################################
# The instance is bought in the Contabo panel and imported with `adopt`.
# Terraform may only rename it; it can never create, reinstall or cancel it.
# `install` and `switch` never run Terraform, so a NixOS change cannot touch
# the infrastructure.

CONTABO_RESOURCE="contabo_instance.${HOST_NAME}"
PLAN_FILE="${STATE_DIR}/plan.tfplan"
PLAN_JSON="${STATE_DIR}/plan.json"
PLAN_GUARD="${NIXCONFIG_PLAN_GUARD:-${REPO_ROOT}/scripts/provisioning/plan-guard.jq}"
HARDWARE_CONFIG="${REPO_ROOT}/hosts/${HOST_NAME}/hardware-configuration.nix"

contabo_load_api_credentials() {
  local pair var key value

  if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$AGE_KEY_PATH" ]]; then
    export SOPS_AGE_KEY_FILE="$AGE_KEY_PATH"
  fi

  for pair in \
    CNTB_OAUTH2_CLIENT_ID:oauth2_client_id \
    CNTB_OAUTH2_CLIENT_SECRET:oauth2_client_secret \
    CNTB_OAUTH2_USER:oauth2_user \
    CNTB_OAUTH2_PASS:oauth2_pass; do
    var="${pair%%:*}"
    key="${pair##*:}"
    if [[ -n "${!var:-}" ]]; then
      continue
    fi
    if ! value="$(sops -d --extract "[\"contabo\"][\"${key}\"]" "$SECRETS_FILE" 2>/dev/null)"; then
      echo "Failed to decrypt contabo.${key} from ${SECRETS_FILE}." >&2
      echo "Add the Contabo API credentials with: sops ${SECRETS_FILE}  (see docs/lab118-services/REFERENCE.md)" >&2
      exit 1
    fi
    export "${var}=${value}"
  done
}

contabo_terraform_init() {
  mkdir -p "$STATE_DIR"
  install -m 0644 "$TERRANIX_CONFIG" "$TF_CONFIG_JSON"
  load_terraform_backend_credentials
  write_terraform_backend_config
  contabo_load_api_credentials
  terraform -chdir="$STATE_DIR" init -input=false -backend-config="$TF_BACKEND_CONFIG" -reconfigure >/dev/null
}

contabo_state_has_instance() {
  terraform -chdir="$STATE_DIR" state list 2>/dev/null | grep -qx "$CONTABO_RESOURCE"
}

# Writes PLAN_FILE and refuses (exit 1) if the plan would create, delete,
# replace, or touch anything but display_name on the instance.
contabo_guarded_plan() {
  local violations

  terraform -chdir="$STATE_DIR" plan -input=false -out="$PLAN_FILE" "$@"
  terraform -chdir="$STATE_DIR" show -json "$PLAN_FILE" > "$PLAN_JSON"
  violations="$(jq -r -f "$PLAN_GUARD" "$PLAN_JSON")"
  if [[ -n "$violations" ]]; then
    rm -f "$PLAN_FILE"
    {
      echo
      echo "REFUSED by plan guard. Nothing was applied:"
      while IFS= read -r violation; do
        echo "  - ${violation}"
      done <<<"$violations"
    } >&2
    exit 1
  fi
  echo "Plan guard: OK (no create, delete, replace or reinstall-sensitive change)."
}

contabo_plan_has_changes() {
  jq -e '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length > 0' "$PLAN_JSON" >/dev/null
}

contabo_target() {
  local target="${TARGET_HOST:-$(host_field deployTarget)}"
  if [[ -z "$target" ]]; then
    echo "No deploy target for ${HOST_NAME}. Set TARGET_HOST or fill hosts/${HOST_NAME}/facts.nix." >&2
    exit 1
  fi
  printf '%s\n' "$target"
}

confirm_by_typing() {
  local prompt="$1"
  local expected="$2"
  local answer=""

  printf '%s\nType "%s" to continue: ' "$prompt" "$expected" >&2
  read -r answer || true
  if [[ "$answer" != "$expected" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
}

contabo_install() {
  local target
  local host_key="${HOST_AGE_KEY_FILE:-}"
  local host_recipient
  local os_release
  local os_id
  local os_variant
  local extra_files

  target="$(contabo_target)"

  if [[ -z "$host_key" || ! -f "$host_key" ]]; then
    echo "Set HOST_AGE_KEY_FILE to the host-scoped age key for ${HOST_NAME} (see docs/lab118-services/REFERENCE.md)." >&2
    exit 1
  fi
  if [[ -f "$AGE_KEY_PATH" ]] && cmp -s "$host_key" "$AGE_KEY_PATH"; then
    echo "Refusing: HOST_AGE_KEY_FILE is the operator age key. Cloud hosts get a dedicated key." >&2
    exit 1
  fi
  host_recipient="$(age-keygen -y "$host_key")"
  if ! grep -qF -- "$host_recipient" "${REPO_ROOT}/.sops.yaml"; then
    echo "Refusing: ${host_recipient} (from HOST_AGE_KEY_FILE) is not a recipient in .sops.yaml." >&2
    exit 1
  fi
  if [[ ! -f "${REPO_ROOT}/secrets/hosts/${HOST_NAME}.yaml" ]]; then
    echo "Refusing: secrets/hosts/${HOST_NAME}.yaml does not exist yet." >&2
    exit 1
  fi
  if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$AGE_KEY_PATH" ]]; then
    export SOPS_AGE_KEY_FILE="$AGE_KEY_PATH"
  fi
  # Decrypted values go straight into jq; only the verdict is used.
  if ! sops -d --output-type json "${REPO_ROOT}/secrets/hosts/${HOST_NAME}.yaml" 2>/dev/null \
      | jq -e '[.. | strings | select(. == "" or . == "pending")] | length == 0' >/dev/null; then
    echo "Refusing: secrets/hosts/${HOST_NAME}.yaml cannot be decrypted or still has 'pending' placeholders." >&2
    exit 1
  fi
  if [[ ! -f "$SSH_PRIVATE_KEY_PATH" ]]; then
    echo "missing bootstrap private key: $SSH_PRIVATE_KEY_PATH (set SSH_PRIVATE_KEY_PATH)" >&2
    exit 1
  fi

  # shellcheck disable=SC2016 # expanded on the target
  if ! os_release="$(ssh -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=15 \
      -i "$SSH_PRIVATE_KEY_PATH" "root@${target}" '. /etc/os-release && printf "%s %s" "$ID" "${VARIANT_ID:-}"')"; then
    echo "Cannot SSH to root@${target} with ${SSH_PRIVATE_KEY_PATH}." >&2
    exit 1
  fi
  read -r os_id os_variant <<<"$os_release"
  # The nixos-anywhere installer (RAM only, VARIANT_ID=installer) is what an
  # interrupted install leaves behind; resuming from it is expected. An
  # installed NixOS system is not.
  if [[ "$os_id" == "nixos" && "${os_variant:-}" == "installer" ]]; then
    echo "Target is running the temporary NixOS installer (an earlier install did not finish); continuing from it."
    os_id="nixos installer (RAM)"
  elif [[ "$os_id" == "nixos" && "${FORCE_REINSTALL:-}" != "$HOST_NAME" ]]; then
    echo "Refusing: root@${target} already runs an installed NixOS. Reinstalling would erase it." >&2
    echo "If that is really intended, re-run with FORCE_REINSTALL=${HOST_NAME}." >&2
    exit 1
  fi

  confirm_by_typing "This ERASES the disk of ${target} (currently: ${os_id}) and installs NixOS host ${HOST_NAME}." "$HOST_NAME"

  extra_files="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now
  trap "rm -rf '${extra_files}'" EXIT
  install -d -m 0755 "${extra_files}/var/lib/sops-nix"
  install -m 0600 "$host_key" "${extra_files}/var/lib/sops-nix/key.txt"

  nixos-anywhere \
    --flake "${REPO_ROOT}#${HOST_NAME}" \
    --target-host "root@${target}" \
    -i "${SSH_PRIVATE_KEY_PATH}" \
    --build-on remote \
    --copy-host-keys \
    --generate-hardware-config nixos-generate-config "${HARDWARE_CONFIG}" \
    --extra-files "${extra_files}"

  echo
  echo "Installed ${HOST_NAME}. Commit ${HARDWARE_CONFIG#"${REPO_ROOT}"/} before the next switch."
}

contabo_main() {
  case "$ACTION" in
    plan)
      contabo_terraform_init
      contabo_guarded_plan "$@"
      ;;
    adopt)
      local instance_id="${1:-}"
      if [[ -z "$instance_id" ]]; then
        echo "usage: nix run .#adopt -- ${HOST_NAME} <contabo-instance-id>" >&2
        exit 1
      fi
      contabo_terraform_init
      if contabo_state_has_instance; then
        echo "${CONTABO_RESOURCE} is already in state; nothing to import."
      else
        terraform -chdir="$STATE_DIR" import -input=false "$CONTABO_RESOURCE" "$instance_id"
      fi
      contabo_guarded_plan
      terraform -chdir="$STATE_DIR" output
      ;;
    provision)
      contabo_terraform_init
      if ! contabo_state_has_instance; then
        echo "Refusing: ${CONTABO_RESOURCE} is not in state. Buy the server in the Contabo panel, then run:" >&2
        echo "  nix run .#adopt -- ${HOST_NAME} <contabo-instance-id>" >&2
        exit 1
      fi
      contabo_guarded_plan "$@"
      if ! contabo_plan_has_changes; then
        echo "No infrastructure changes."
        exit 0
      fi
      terraform -chdir="$STATE_DIR" show "$PLAN_FILE"
      confirm_by_typing "Apply the plan above to ${HOST_NAME}?" "$HOST_NAME"
      terraform -chdir="$STATE_DIR" apply -input=false "$PLAN_FILE"
      ;;
    install)
      contabo_install
      ;;
    switch)
      run_nixos_switch "$HOST_NAME" "$SWITCH_USER" "$(contabo_target)"
      ;;
    destroy|migrate-state)
      echo "Refusing: '${ACTION}' is not supported for Contabo host ${HOST_NAME}." >&2
      echo "Terraform destroy would cancel the Contabo contract. Cancel or reinstall only in the Contabo panel, deliberately." >&2
      exit 1
      ;;
    *)
      echo "unsupported action: $ACTION" >&2
      exit 1
      ;;
  esac
}

case "$HOST_PLATFORM" in
  contabo)
    contabo_main "$@"
    exit 0
    ;;
  proxmox)
    ;;
  *)
    echo "unsupported platform for ${HOST_NAME}: ${HOST_PLATFORM}" >&2
    exit 1
    ;;
esac

############################################################
## Proxmox hosts
############################################################

mkdir -p "$STATE_DIR"

install -m 0644 "$TERRANIX_CONFIG" "$TF_CONFIG_JSON"

load_terraform_backend_credentials
write_terraform_backend_config
backup_local_state_before_adopt

rm -rf "$EXTRA_FILES_DIR"
mkdir -p "$EXTRA_FILES_DIR"

if [[ -n "${AGE_KEY_PATH}" && -f "${AGE_KEY_PATH}" ]]; then
  mkdir -p "$EXTRA_FILES_DIR/home/justin/.config/sops/age"
  install -m 0400 "$AGE_KEY_PATH" "$EXTRA_FILES_DIR/home/justin/.config/sops/age/keys.txt"
fi

terraform_init_args=(
  -input=false
  -backend-config="$TF_BACKEND_CONFIG"
)

case "$ACTION" in
  migrate-state)
    terraform_init_args+=(-migrate-state -force-copy)
    ;;
  adopt|plan|provision|install|switch|destroy)
    terraform_init_args+=(-reconfigure)
    ;;
esac

terraform -chdir="$STATE_DIR" init "${terraform_init_args[@]}" >/dev/null

if [[ "$ACTION" == "migrate-state" ]]; then
  echo "Migrated Terraform state for ${HOST_NAME} to ${TF_STATE_BUCKET}/${TF_STATE_KEY_PREFIX}/${HOST_NAME}/terraform.tfstate"
  exit 0
fi

current_bootstrap_public_key() {
  {
    terraform -chdir="$STATE_DIR" state show "proxmox_virtual_environment_vm.${HOST_NAME}" 2>/dev/null || true
  } | awk '
        /^[[:space:]]*keys[[:space:]]*=/ { in_keys = 1; next }
        in_keys && /^[[:space:]]*]/ { exit }
        in_keys && /ssh-|ecdsa-|sk-/ {
          gsub(/^[[:space:]"]+/, "")
          gsub(/[",[:space:]]+$/, "")
          print
          exit
        }
      '
}

is_public_key() {
  [[ "$1" =~ ^(ssh-|ecdsa-|sk-) && "$1" != *"placeholder-bootstrap-key"* ]]
}

BOOTSTRAP_PUBLIC_KEY="$(current_bootstrap_public_key)"

if ! is_public_key "$BOOTSTRAP_PUBLIC_KEY"; then
  BOOTSTRAP_PUBLIC_KEY=""
fi

if [[ -z "$BOOTSTRAP_PUBLIC_KEY" ]]; then
  if [[ -f "$SSH_PUBLIC_KEY_PATH" ]]; then
    BOOTSTRAP_PUBLIC_KEY="$(tr -d '\n' < "$SSH_PUBLIC_KEY_PATH")"
  elif [[ -f "$SSH_PRIVATE_KEY_PATH" ]]; then
    ssh-keygen -y -f "$SSH_PRIVATE_KEY_PATH" > "$SSH_PUBLIC_KEY_PATH"
    BOOTSTRAP_PUBLIC_KEY="$(tr -d '\n' < "$SSH_PUBLIC_KEY_PATH")"
  fi
fi

if ! is_public_key "$BOOTSTRAP_PUBLIC_KEY"; then
  BOOTSTRAP_PUBLIC_KEY=""
fi

if [[ -z "$BOOTSTRAP_PUBLIC_KEY" ]]; then
  BOOTSTRAP_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA placeholder-bootstrap-key"
fi

jq -n \
  --arg bootstrap_public_key "$BOOTSTRAP_PUBLIC_KEY" \
  '{
    bootstrap_public_key: $bootstrap_public_key
  }' > "$TF_VARS_JSON"

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

  if [[ ! -f "$SSH_PRIVATE_KEY_PATH" ]]; then
    echo "missing bootstrap private key: $SSH_PRIVATE_KEY_PATH" >&2
    exit 1
  fi

  nixos-anywhere \
    --flake "${REPO_ROOT}#${host_name}" \
    --target-host "${target_user}@${target_ip}" \
    -i "${SSH_PRIVATE_KEY_PATH}" \
    --generate-hardware-config nixos-generate-config "${hardware_config}" \
    --extra-files "${EXTRA_FILES_DIR}"
}

terraform_apply_and_discover() {
  local outputs_json="$1"
  local node_name_ref="$2"
  local vm_id_ref="$3"
  local target_user_ref="$4"
  local discovered_ip_ref="$5"
  shift 5

  terraform -chdir="$STATE_DIR" apply -input=false -auto-approve -var-file="$TF_VARS_JSON" "$@"
  terraform -chdir="$STATE_DIR" output -json > "$outputs_json"

  printf -v "$node_name_ref" '%s' "$(jq -r '.node_name.value' "$outputs_json")"
  printf -v "$vm_id_ref" '%s' "$(jq -r '.vm_id.value' "$outputs_json")"
  printf -v "$target_user_ref" '%s' "$(jq -r '.target_user.value' "$outputs_json")"
  printf -v "$discovered_ip_ref" '%s' "$(discover_vm_ip "${!node_name_ref}" "${!vm_id_ref}")"

  echo "Discovered DHCP IP for ${HOST_NAME}: ${!discovered_ip_ref}"
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
  provision|install|switch)
    HARDWARE_CONFIG="${REPO_ROOT}/hosts/${HOST_NAME}/hardware-configuration.nix"
    OUTPUTS_JSON="${STATE_DIR}/outputs.json"
    # shellcheck disable=SC2034 # assigned through printf -v in terraform_apply_and_discover
    NODE_NAME=""
    # shellcheck disable=SC2034 # assigned through printf -v in terraform_apply_and_discover
    VM_ID=""
    TARGET_USER=""
    DISCOVERED_IP=""

    guard_against_duplicate_vm

    terraform_apply_and_discover "$OUTPUTS_JSON" NODE_NAME VM_ID TARGET_USER DISCOVERED_IP "$@"

    if [[ "$ACTION" == "switch" ]]; then
      run_nixos_switch "$HOST_NAME" "$SWITCH_USER" "$DISCOVERED_IP"
      exit 0
    fi

    if [[ "$ACTION" == "provision" && -f "$HARDWARE_CONFIG" ]]; then
      run_nixos_switch "$HOST_NAME" "$SWITCH_USER" "$DISCOVERED_IP"
      exit 0
    fi

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
