# Behavioural tests for provision-host.sh. terraform, nixos-rebuild,
# nixos-anywhere, ssh, sops and curl are fakes that record their arguments,
# so the tests prove which external actions each command would take.
#
# usage: run.sh <provision-host.sh> <plan-guard.jq> <infra manifest json>
set -euo pipefail

SCRIPT="$1"
GUARD="$2"
MANIFEST="$3"
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
case " $* " in
  *" --output-type json "*) echo "${FAKE_HOST_SECRETS:-{\"doppler\":{\"service-token\":\"dp.st.prd.x\"},\"root\":{\"console-password-hash\":\"\$y\$x\"}}}" ;;
  *) echo "fake-value" ;;
esac
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS/curl"
case "$*" in
  *cluster/resources*) echo '{"data":[]}' ;;
  *network-get-interfaces*) echo '{"data":{"result":[{"name":"ens18","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.0.50"}]}]}}' ;;
esac
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH"
export CALLS="$T/calls"
export NIXCONFIG_INFRA_HOSTS="$MANIFEST"
export NIXCONFIG_PLAN_GUARD="$GUARD"
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

echo "== proxmox hosts keep their flow"
run switch dockhand
check "proxmox switch exits 0" rc_is 0
check "proxmox switch still applies terraform first" called_with terraform "apply -input=false -auto-approve"
check "proxmox switch targets the discovered IP" called_with nixos-rebuild "--target-host justin@10.0.0.50"
run destroy dockhand
check "proxmox destroy unchanged" called_with terraform "destroy -input=false -auto-approve"

echo "== unknown host"
run switch no-such-host
check "unknown host refused" rc_not_zero
check "  ...and lists known hosts" output_has "known hosts:"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
