# Behavioural tests for provision-host.sh. terraform, nixos-rebuild,
# nixos-anywhere, ssh, sops and curl are fakes that record their arguments,
# so the tests prove which external actions each command would take.
#
# usage: run.sh <provision-host.sh> <plan-guard.jq> <infra manifest json> <proxmox-plan-guard.jq>
set -euo pipefail

SCRIPT="$1"
GUARD="$2"
MANIFEST="$3"
PROXMOX_GUARD="$4"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    fail=$((fail + 1))
  fi
}

HOST=lab118-services
REPO="$T/repo"
mkdir -p "$REPO/secrets/hosts" "$REPO/hosts/$HOST" "$T/bin" "$T/calls"
age-keygen -o "$T/host.key" 2>/dev/null
age-keygen -o "$T/operator.key" 2>/dev/null
age-keygen -o "$T/other.key" 2>/dev/null
cat >"$REPO/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^secrets/hosts/${HOST}\.yaml\$
    key_groups:
      - age:
          - $(age-keygen -y "$T/host.key")
          - $(age-keygen -y "$T/operator.key")
EOF
touch "$REPO/secrets/hosts/$HOST.yaml" "$REPO/secrets/secrets.yaml"

# A Proxmox host that installs with its own age key, built from dockhand's
# entry so these tests don't depend on a real keyed host.
KEYED=keyed-vm
KEYED_MANIFEST="$T/manifest-keyed.json"
jq --arg h "$KEYED" '. + {($h): (.dockhand + {hostAgeKey: true})}' "$MANIFEST" >"$KEYED_MANIFEST"
mkdir -p "$REPO/hosts/$KEYED"
touch "$REPO/secrets/hosts/$KEYED.yaml"
echo "fake private key" >"$T/bootstrap_key"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE test" >"$T/bootstrap_key.pub"

cat >"$T/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >>"$CALLS/terraform"
case " $* " in
  *" state list "*)
    [[ "${FAKE_STATE:-}" == contabo ]] && echo "contabo_instance.lab118-services"
    [[ "${FAKE_STATE:-}" == proxmox ]] && echo "proxmox_virtual_environment_vm.dockhand"
    exit 0 ;;
  *" state show "*) exit 0 ;;
  *" show -json "*) cat "$FAKE_PLAN_JSON" ;;
  *" output -json "*) echo '{"node_name":{"value":"proxmox5"},"vm_id":{"value":"105"},"target_user":{"value":"root"}}' ;;
  *) exit 0 ;;
esac
EOF
cat >"$T/bin/nixos-anywhere" <<'EOF'
#!/usr/bin/env bash
echo "nixos-anywhere $*" >>"$CALLS/nixos-anywhere"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --extra-files ]]; then
    (cd "$2" && find . -type f | sort) >"$CALLS/extra-files.list"
    stat -c %a "$2/var/lib/sops-nix/key.txt" >"$CALLS/extra-files.mode" 2>/dev/null || true
    cp "$2/var/lib/sops-nix/key.txt" "$CALLS/extra-files.key" 2>/dev/null || true
    echo "$2" >"$CALLS/extra-files.dir"
  fi
  shift
done
EOF
cat >"$T/bin/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
echo "nixos-rebuild $*" >>"$CALLS/nixos-rebuild"
EOF
cat >"$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >>"$CALLS/ssh"
printf '%s' "${FAKE_OS_ID:-ubuntu}"
EOF
cat >"$T/bin/sops" <<'EOF'
#!/usr/bin/env bash
echo "sops $*" >>"$CALLS/sops"
echo "key=${SOPS_AGE_KEY_FILE:-} home=${HOME:-}" >>"$CALLS/sops-env"
# Defaults live in variables: "${VAR:-{...}}" would close at the first brace
# and append the rest when VAR is set.
default_secrets='{"doppler":{"service-token":"dp.st.prd.x"},"root":{"console-password-hash":"$y$x"}}'
case " $* " in
  *" --output-type json "*)
    if [[ -n "${FAKE_SOPS_DENY_KEY:-}" && "${SOPS_AGE_KEY_FILE:-}" == "$FAKE_SOPS_DENY_KEY" ]]; then
      echo "failed to decrypt" >&2
      exit 1
    fi
    echo "${FAKE_HOST_SECRETS:-$default_secrets}" ;;
  *) echo "fake-value" ;;
esac
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS/curl"
no_vms='{"data":[]}'
case "$*" in
  *cluster/resources*) echo "${FAKE_CLUSTER_RESOURCES:-$no_vms}" ;;
  *network-get-interfaces*) echo '{"data":{"result":[{"name":"ens18","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.0.50"}]}]}}' ;;
esac
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH"
export CALLS="$T/calls"
export NIXCONFIG_INFRA_HOSTS="$MANIFEST"
export NIXCONFIG_PLAN_GUARD="$GUARD"
export NIXCONFIG_PROXMOX_PLAN_GUARD="$PROXMOX_GUARD"
export NIXCONFIG_REPO_ROOT="$REPO"
export SOPS_AGE_KEY_PATH="$T/operator.key"
export SSH_PRIVATE_KEY_PATH="$T/bootstrap_key"
export AWS_ACCESS_KEY_ID=fake AWS_SECRET_ACCESS_KEY=fake
export CNTB_OAUTH2_CLIENT_ID=fake CNTB_OAUTH2_CLIENT_SECRET=fake CNTB_OAUTH2_USER=fake CNTB_OAUTH2_PASS=fake
export PROXMOX_VE_ENDPOINT=https://proxmox.example:8006 PROXMOX_VE_API_TOKEN=user@pam!t=fake

run() { # action, host, args... ; stdin is passed through
  local action="$1"
  shift
  rm -f "$CALLS"/*
  RC=0
  NIX_INFRA_ACTION="$action" bash "$SCRIPT" "$@" >"$T/out.log" 2>&1 || RC=$?
}
rc_is() { [[ "$RC" == "$1" ]]; }
rc_not_zero() { [[ "$RC" != 0 ]]; }
not_called() { [[ ! -s "$CALLS/$1" ]]; }
called_with() { grep -qF -- "$2" "$CALLS/$1"; }
not_called_with() { ! grep -qF -- "$2" "$CALLS/$1" 2>/dev/null; }
output_has() { grep -qF -- "$1" "$T/out.log"; }

# Plan fixtures, shaped like `terraform show -json`.
plan() { # actions-json before-json after-json [after_unknown-json]
  local unknown="${4:-}"
  [[ -n "$unknown" ]] || unknown='{}'
  jq -n --argjson a "$1" --argjson b "$2" --argjson c "$3" --argjson u "$unknown" --arg t contabo_instance \
    '{resource_changes: [{address: "\($t).lab118-services", type: $t, change: {actions: $a, before: $b, after: $c, after_unknown: $u}}]}' \
    >"$T/plan.json"
  export FAKE_PLAN_JSON="$T/plan.json"
}
before='{"display_name":"vmi123","image_id":"ubuntu-24.04","product_id":"V156","ssh_keys":[]}'
proxmox_plan() { # actions-json
  jq -n --argjson a "$1" --arg t proxmox_virtual_environment_vm \
    '{resource_changes: [{address: "\($t).dockhand", type: $t, change: {actions: $a, before: {}, after: {}}}]}' \
    >"$T/plan-proxmox.json"
  export FAKE_PLAN_JSON="$T/plan-proxmox.json"
}

echo "== cloud switch"
run switch "$HOST"
check "exits 0" rc_is 0
check "never runs terraform" not_called terraform
check "nixos-rebuild targets the deploy target from facts" called_with nixos-rebuild "--target-host justin@89.117.73.89"
check "builds on the target" called_with nixos-rebuild "--build-host justin@89.117.73.89"
TARGET_HOST=198.51.100.7 run switch "$HOST"
check "TARGET_HOST overrides the deploy target" called_with nixos-rebuild "--target-host justin@198.51.100.7"

echo "== cloud destroy / migrate-state"
for action in destroy migrate-state; do
  run "$action" "$HOST"
  check "$action refused" rc_not_zero
  check "$action never runs terraform" not_called terraform
done

echo "== cloud install guards"
FAKE_OS_ID=nixos HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"$HOST"
check "refuses when target already runs NixOS" rc_not_zero
check "  ...without running nixos-anywhere" not_called nixos-anywhere
check "  ...and explains FORCE_REINSTALL" output_has "FORCE_REINSTALL=$HOST"
HOST_AGE_KEY_FILE="$T/operator.key" run install "$HOST" <<<"$HOST"
check "refuses the operator age key" rc_not_zero
check "  ...with a clear reason" output_has "is the operator age key"
check "  ...without running nixos-anywhere" not_called nixos-anywhere
HOST_AGE_KEY_FILE="$T/other.key" run install "$HOST" <<<"$HOST"
check "refuses a key that is not a .sops.yaml recipient" rc_not_zero
check "  ...without running nixos-anywhere" not_called nixos-anywhere
run install "$HOST" <<<"$HOST"
check "refuses without HOST_AGE_KEY_FILE" rc_not_zero
FAKE_HOST_SECRETS='{"doppler":{"service-token":"pending"},"root":{"console-password-hash":"$y$x"}}' \
  HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"$HOST"
check "refuses while the host SOPS file has placeholders" rc_not_zero
check "  ...with a clear reason" output_has "placeholders"
check "  ...without running nixos-anywhere" not_called nixos-anywhere
HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"no"
check "aborts on wrong confirmation" rc_not_zero
check "  ...without running nixos-anywhere" not_called nixos-anywhere

echo "== cloud install"
HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"$HOST"
check "exits 0" rc_is 0
check "never runs terraform" not_called terraform
check "connects to the deploy target as root" called_with nixos-anywhere "--target-host root@89.117.73.89"
check "builds on the target" called_with nixos-anywhere "--build-on remote"
check "keeps the existing SSH host keys" called_with nixos-anywhere "--copy-host-keys"
check "ships only the host key" [ "$(cat "$CALLS/extra-files.list")" = "./var/lib/sops-nix/key.txt" ]
check "host key is mode 0600" [ "$(cat "$CALLS/extra-files.mode")" = 600 ]
check "shipped key is the host key" cmp -s "$CALLS/extra-files.key" "$T/host.key"
check "temporary extra-files dir removed" [ ! -e "$(cat "$CALLS/extra-files.dir")" ]
FAKE_OS_ID=nixos FORCE_REINSTALL="$HOST" HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"$HOST"
check "explicit FORCE_REINSTALL allows reinstalling NixOS" called_with nixos-anywhere "--flake"
FAKE_OS_ID="nixos installer" HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"$HOST"
check "resumes from the nixos-anywhere installer (interrupted install)" called_with nixos-anywhere "--flake"
check "  ...and says so" output_has "temporary NixOS installer"
FAKE_OS_ID="nixos installer" HOST_AGE_KEY_FILE="$T/host.key" run install "$HOST" <<<"no"
check "  ...still requires the typed confirmation" not_called nixos-anywhere

echo "== cloud plan guard"
plan '["no-op"]' "$before" "$before"
run plan "$HOST"
check "no-op plan passes" rc_is 0
check "plan never applies" not_called_with terraform " apply"
plan '["update"]' "$before" "$(jq -c '.display_name="lab118-services"' <<<"$before")"
run plan "$HOST"
check "display_name-only update passes" rc_is 0
for attribute in image_id ssh_keys user_data root_password default_user product_id; do
  plan '["update"]' "$before" "$(jq -c --arg k "$attribute" '.[$k]="changed"' <<<"$before")"
  run plan "$HOST"
  check "update of $attribute refused" rc_is 1
  check "  ...names $attribute" output_has "$attribute"
done
plan '["update"]' "$before" "$before" '{"user_data":true}'
run plan "$HOST"
check "attribute becoming unknown is refused" rc_is 1
plan '["delete"]' "$before" 'null'
run plan "$HOST"
check "delete (cancel contract) refused" rc_is 1
plan '["delete","create"]' "$before" "$before"
run plan "$HOST"
check "replace refused" rc_is 1
plan '["create"]' 'null' "$before"
run plan "$HOST"
check "create (purchase) refused" rc_is 1

echo "== cloud provision"
plan '["update"]' "$before" "$(jq -c '.display_name="lab118-services"' <<<"$before")"
run provision "$HOST" <<<"$HOST"
check "refuses when the instance is not in state" rc_not_zero
check "  ...without applying" not_called_with terraform " apply"
FAKE_STATE=contabo run provision "$HOST" <<<"$HOST"
check "applies a guarded rename after confirmation" called_with terraform "apply -input=false"
check "  ...using the reviewed plan file" called_with terraform "plan.tfplan"
FAKE_STATE=contabo run provision "$HOST" <<<"no"
check "does not apply without confirmation" not_called_with terraform " apply"
plan '["no-op"]' "$before" "$before"
FAKE_STATE=contabo run provision "$HOST" <<<"$HOST"
check "no changes: nothing applied" not_called_with terraform " apply"
plan '["update"]' "$before" "$(jq -c '.image_id="debian-12"' <<<"$before")"
FAKE_STATE=contabo run provision "$HOST" <<<"$HOST"
check "reinstall-sensitive plan: nothing applied" not_called_with terraform " apply"

echo "== proxmox host-key install guards"
proxmox_plan '["no-op"]'
keyed() { NIXCONFIG_INFRA_HOSTS="$KEYED_MANIFEST" run "$@"; }
keyed install "$KEYED"
check "refuses without HOST_AGE_KEY_FILE" rc_not_zero
check "  ...before running terraform" not_called terraform
check "  ...without running nixos-anywhere" not_called nixos-anywhere
HOST_AGE_KEY_FILE="$T/operator.key" keyed install "$KEYED"
check "refuses the operator age key" rc_not_zero
check "  ...with a clear reason" output_has "is the operator age key"
check "  ...before running terraform" not_called terraform
HOST_AGE_KEY_FILE="$T/other.key" keyed install "$KEYED"
check "refuses a key that is not a .sops.yaml recipient" rc_not_zero
check "  ...before running terraform" not_called terraform
FAKE_HOST_SECRETS='{"homarr":{"secret-encryption-key":"pending"}}' \
  HOST_AGE_KEY_FILE="$T/host.key" keyed install "$KEYED"
check "refuses while the host SOPS file has placeholders" rc_not_zero
check "  ...before running terraform" not_called terraform
FAKE_SOPS_DENY_KEY="$T/host.key" HOST_AGE_KEY_FILE="$T/host.key" keyed install "$KEYED"
check "refuses when the host key cannot decrypt the host file" rc_not_zero
check "  ...with a clear reason" output_has "cannot be decrypted with HOST_AGE_KEY_FILE"
check "  ...before running terraform" not_called terraform
FAKE_HOST_SECRETS='{"homarr":{"secret-encryption-key":"0123abcd"}}' \
  HOST_AGE_KEY_FILE="$T/host.key" keyed install "$KEYED"
check "accepts a host SOPS file without placeholders" rc_is 0
rm "$REPO/secrets/hosts/$KEYED.yaml"
HOST_AGE_KEY_FILE="$T/host.key" keyed install "$KEYED"
check "refuses without secrets/hosts/<host>.yaml" rc_not_zero
touch "$REPO/secrets/hosts/$KEYED.yaml"

echo "== proxmox host-key install"
decrypted_with_host_key_alone() {
  grep -qF "key=$T/host.key home=" "$CALLS/sops-env" && ! grep -qxF "key=$T/host.key home=$HOME" "$CALLS/sops-env"
}
no_operator_key_in_state() {
  [[ -z "$(find "$REPO/.state/terraform/$KEYED" -name keys.txt -o -name key.txt 2>/dev/null)" ]]
}
HOST_AGE_KEY_FILE="$T/host.key" keyed install "$KEYED"
check "exits 0" rc_is 0
check "installs on the discovered IP" called_with nixos-anywhere "--target-host root@10.0.0.50"
check "ships only the host key" [ "$(cat "$CALLS/extra-files.list")" = "./var/lib/sops-nix/key.txt" ]
check "host key is mode 0600" [ "$(cat "$CALLS/extra-files.mode")" = 600 ]
check "shipped key is the host key" cmp -s "$CALLS/extra-files.key" "$T/host.key"
check "temporary extra-files dir removed" [ ! -e "$(cat "$CALLS/extra-files.dir")" ]
check "no age key left under .state" no_operator_key_in_state
check "decrypt check used the host key and an empty HOME" decrypted_with_host_key_alone
HOST_AGE_KEY_FILE="$T/host.key" keyed provision "$KEYED"
check "provision without a hardware file installs with the host key" called_with nixos-anywhere "--flake"
touch "$REPO/hosts/$KEYED/hardware-configuration.nix"
keyed provision "$KEYED"
check "provision with a hardware file switches without a key" rc_is 0
check "  ...using nixos-rebuild" called_with nixos-rebuild "--target-host justin@10.0.0.50"
check "  ...and never nixos-anywhere" not_called nixos-anywhere
keyed switch "$KEYED"
check "switch needs no host key" rc_is 0
rm "$REPO/hosts/$KEYED/hardware-configuration.nix"

echo "== dashboard"
check "the real manifest gives dashboard a host-scoped key" [ "$(jq -r .dashboard.hostAgeKey "$MANIFEST")" = true ]
run install dashboard
check "installing dashboard without HOST_AGE_KEY_FILE is refused" rc_not_zero
check "  ...before running terraform" not_called terraform

echo "== proxmox bootstrap key"
SSH_PRIVATE_KEY_PATH="$T/no-such-key" run install dockhand
check "install refuses without the bootstrap private key" rc_not_zero
check "  ...with a clear reason" output_has "missing bootstrap private key: $T/no-such-key"
check "  ...before running terraform" not_called terraform
touch "$REPO/hosts/$KEYED/hardware-configuration.nix"
SSH_PRIVATE_KEY_PATH="$T/no-such-key" keyed provision "$KEYED"
check "provision with a hardware file needs no bootstrap key" rc_is 0
SSH_PRIVATE_KEY_PATH="$T/no-such-key" keyed switch "$KEYED"
check "switch needs no bootstrap key" rc_is 0
rm "$REPO/hosts/$KEYED/hardware-configuration.nix"

echo "== proxmox hosts keep their flow"
run install dockhand
check "dockhand install still ships the operator key" [ "$(cat "$CALLS/extra-files.list")" = "./home/justin/.config/sops/age/keys.txt" ]
run switch dockhand
check "proxmox switch exits 0" rc_is 0
check "proxmox switch still applies terraform first" called_with terraform "apply -input=false"
check "  ...using the reviewed plan file" called_with terraform "plan.tfplan"
check "  ...never auto-approving an apply" not_called_with terraform "apply -input=false -auto-approve"
check "proxmox switch targets the discovered IP" called_with nixos-rebuild "--target-host justin@10.0.0.50"
run destroy dockhand
check "proxmox destroy unchanged" called_with terraform "destroy -input=false -auto-approve"

echo "== proxmox plan guard"
for actions in '["delete"]' '["delete","create"]' '["create","delete"]'; do
  proxmox_plan "$actions"
  FAKE_STATE=proxmox run switch dockhand
  check "switch refuses $actions" rc_is 1
  check "  ...without applying" not_called_with terraform " apply"
  check "  ...without touching the VM" not_called nixos-rebuild
done
proxmox_plan '["update"]'
FAKE_STATE=proxmox run switch dockhand
check "an in-place update is applied" called_with terraform "apply -input=false"
proxmox_plan '["delete"]'
run destroy dockhand
check "destroy is not guarded" called_with terraform "destroy -input=false -auto-approve"

echo "== proxmox VM moved by HA"
proxmox_plan '["no-op"]'
FAKE_STATE=proxmox FAKE_CLUSTER_RESOURCES='{"data":[{"vmid":105,"node":"proxmox7","name":"dockhand"}]}' run switch dockhand
check "exits 0" rc_is 0
check "looks the VM up on the node it runs on now" called_with curl "/nodes/proxmox7/qemu/105/agent/network-get-interfaces"
check "  ...and says it moved" output_has "runs on proxmox7, not proxmox5"
check "  ...then switches it" called_with nixos-rebuild "--target-host justin@10.0.0.50"
FAKE_STATE=proxmox run switch dockhand
check "falls back to the Terraform node when the cluster doesn't list it" called_with curl "/nodes/proxmox5/qemu/105/agent/network-get-interfaces"

echo "== unknown host"
run switch no-such-host
check "unknown host refused" rc_not_zero
check "  ...and lists known hosts" output_has "known hosts:"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
