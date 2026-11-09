# LAB-156 verification record

Initially observed on workbench, 2026-11-08, against the LAB-156 worktree
based on 33f360d759e71e7bf66d2810a82426ac8eed52cc. Updated 2026-11-09 after
Justin's encrypted-file commit 2c9b4eb20a787248e884cec61ba8f287dd800dac.
No host was built or deployed.

## Executed checks

`nixfmt` 1.5.0 formatted the new host/test/terranix files; its `--check`
passed. `git diff --check` passed.

`scripts/flake-check.sh eval` ran as a background job and was awaited.
All non-legacy existing hosts passed. The exact summary was:

    failed: home-assistant

That initial production configuration failed closed because the encrypted
host file was not yet present. The explicit missing-SOPS assertion is
retained. Infra did not author a placeholder or inspect secret values.
The existing hosts were not excluded to hide a failure. This prerequisite
is now resolved by Justin's encrypted-file commit; see the follow-up below.

`scripts/flake-check.sh checks` also ran as a background job and was awaited.
All existing checks passed; its initial exact summary was:

    failed: home-assistant-runtime

The failure was in the new test harness, not suppressed: the upstream
`hass --script check_config` dispatcher tried to pip-bootstrap its exact
optional colorlog version despite nixpkgs packaging dependencies itself.
The final test uses the upstream schema checker in the same no-pip mode
as nixpkgs' normal hass wrapper and explicitly imports each selected
protocol's config flow. Matter's CLI is checked in a separate Python
environment so HA's Matter client cannot shadow the server package.
No exposure assertion or package deny list was relaxed.

Following the repository instruction to rerun only failed/changed checks,
the final targeted invocation was:

    scripts/flake-check.sh checks home-assistant-runtime home-assistant-eval home-assistant-exposure-guards home-assistant-backup
    ok    home-assistant-runtime                   20s
    ok    home-assistant-eval                      10s
    ok    home-assistant-exposure-guards           37s
    ok    home-assistant-backup                    2s
    all passed

The positive full-host fixture evaluates every production assertion except
real SOPS file validation, using the same test-only pattern as automation.
Negative regression cases include the missing-file validation guard, backend
exposure, source/interface firewall restrictions, IPv6, unattended upgrades,
backup/restore quiescing and monitoring listener restrictions.

The runtime check executed the pinned Matter 8.1.2 application's CLI/imports,
HA 2026.10.4 YAML schema checking and selected integration imports, including
native `llama_cpp`. This is not service startup, OTA-provider execution,
radio pairing, voice behavior or operational Matter compatibility proof.
The synthetic encrypted backup/restore test exercised recorder SQLite,
a Zigbee SQLite database, HA `.storage`, Matter fabric/cache files and fake
service-stop/start calls. It did not contact the NAS or control real services.
The existing `sqlite-backup` behavioral suite passed in the full check run.

Not checked here: the darwin hosts (CI checks them) and the legacy hosts.
No host builds, especially no inference/CUDA build, were performed.

## Resource and build planning

Rendered and read `terranixConfigurations.x86_64-linux.home-assistant`:
one new `proxmox_virtual_environment_vm.home-assistant` and one
`proxmox_haresource.home-assistant`, node proxmox4, automatic ID (no vm_id
specified), MAC 02:01:18:00:00:0b, 4 cores, 8192 MiB, 64 GiB disk and
cloud-init on nas-shared, template 9999 from proxmox8, no USB/hostpci/q35
change. No existing host/helper resource was modified.

This is a rendered-resource review, NOT a Terraform state-backed plan.
No backend/provider credentials, state, live API-token permissions or device
mappings were accessed. USB permission/version investigation is not needed
for the selected no-passthrough design. Justin must inspect an approved
actual plan before provision; template clone/ID compatibility remains a
live prerequisite, not a guaranteed result from rendering JSON.

Executed the exact production dry-run:

    nix build --dry-run .#nixosConfigurations.home-assistant.config.system.build.toplevel

The initial attempt refused at the missing-SOPS assertion. A separate
test-fixture dry-run using `extendModules` and `eval-test.nix` succeeded,
reporting 110 derivations to build. After Justin's encrypted-file commit,
the exact production command above also exited 0, reporting 110 derivations
to build. Neither dry-run built the host, and the fixture is never deployed.

## 2026-11-09 secure-preparation follow-up

Board approval 247a4edd-d793-43d6-a3d6-3c522f322a5d was read back as approved
at 2026-11-09T04:09:34.454Z. Scope: Justin-only dedicated key/public recipient
and encrypted host declarations, not provisioning or other live changes.
PR metadata identified commit 2c9b4eb20a787248e884cec61ba8f287dd800dac,
"Add Home Assistant's age key and secrets", changing only `.sops.yaml`
and `secrets/hosts/home-assistant.yaml`. Infra fast-forwarded the existing
branch without opening/decrypting either file or printing a secret diff.

Real production evaluation, with missing-file validation still enabled:

    scripts/flake-check.sh eval home-assistant
    ok    home-assistant                           10s
    all passed

Affected checks were rerun as a background job and awaited:

    scripts/flake-check.sh checks home-assistant-eval home-assistant-exposure-guards home-assistant-runtime home-assistant-backup
    ok    home-assistant-eval                      9s
    ok    home-assistant-exposure-guards           40s
    ok    home-assistant-runtime                   10s
    ok    home-assistant-backup                    2s
    all passed

All previous existing-host/check results above remain the recorded full
repository pass evidence; only affected checks were rerun as required.
Production encrypted-file validation and dry-run do not prove credentials
work, enrollment exists or secret population has been exercised live.
No secret values were read and no host was built, installed or switched.

## Operator actions after review and exact-scope approvals

The dedicated public recipient/encrypted declarations have been added by
Justin and production evaluation/dry-run now pass. The host private key is
not the operator's key and remains outside the repository. Never post any
private key, token, password hash or pairing code in this record or PR.

Once the fresh VM's DHCP/DNS mapping and the other prerequisites are
individually approved, the repository interfaces are:

    nix run .#plan -- home-assistant
    HOST_AGE_KEY_FILE=<dedicated-host-key-file> nix run .#provision -- home-assistant
    nix run .#switch -- home-assistant

The last command is for later approved switches; provision already installs.
These commands were validated against flake apps and provision-host.sh, not
executed. The existing home-assistant DNS record must not silently direct
an operator switch at an old guest.

Outside-repository work awaits Justin: supply/commission the selected
network hardware (purchase approval is separate); assign/verify a unique
DHCP reservation and DNS mapping for the new MAC; prepare the proposed NAS
export/permissions; register outbound Beszel and the backup push monitor;
securely populate credentials; fresh HA, ZHA, Thread/Matter, ESPHome/BLE,
Wyoming, llama.cpp and HomeKit onboarding; check actual IPv6/mDNS, device
coverage, backups and a new-system restore drill. No old inventory,
migration, old-backup retention, cutover or cleanup prerequisite is added.

Status: source, targeted runtime/recovery checks and production evaluation/
dry-run are ready for the attached Reviewer stage. No merge/provision/switch/
live acceptance is claimed. Reviewer approval is not a board approval.
Automatic dependency PRs already come from
`.github/workflows/update-flake-lock.yml`; no unattended switch timer is
introduced. Schema rollback requires matching pre-upgrade data as well as
the old Nix generation, as detailed in REFERENCE.md.
