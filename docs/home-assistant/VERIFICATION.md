# LAB-156 verification record

Observed on workbench, 2026-11-08, against the LAB-156 worktree based on
33f360d759e71e7bf66d2810a82426ac8eed52cc. No host was built or deployed.

## Executed checks

`nixfmt` 1.5.0 formatted the new host/test/terranix files; its `--check`
passed. `git diff --check` passed.

`scripts/flake-check.sh eval` ran as a background job and was awaited.
All non-legacy existing hosts passed. The exact summary was:

    failed: home-assistant

That new production configuration fails closed because Justin has not yet
created `secrets/hosts/home-assistant.yaml`. The explicit missing-SOPS
assertion is retained. No placeholder encrypted file or actual key/token
was authored/read. The existing hosts were not excluded to hide a failure.

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

It refused at the missing-SOPS assertion. A separate test-fixture dry-run
using `extendModules` and `eval-test.nix` succeeded, reporting 110 derivations
to build. This shows closure availability/planning only; nothing built the
host and the fixture is not a deployable substitute for the real SOPS file.

## Operator actions after review and exact-scope approvals

First resolve the dedicated host encryption recipient and populate the
required SOPS entries securely; production eval/CI must then pass with real
encrypted declarations. The host key is not the operator's key. Never post
any private key, token, password hash or pairing code in this record or PR.

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

Status: source and secret-free tests prepared; production eval/dry-run remain
blocked on the missing encrypted host file. No merge/provision/switch/live
acceptance is claimed. Reviewer stage remains attached to LAB-156 and is
not a board approval. Automatic dependency PRs already come from
`.github/workflows/update-flake-lock.yml`; no unattended switch timer is
introduced. Schema rollback requires matching pre-upgrade data as well as
the old Nix generation, as detailed in REFERENCE.md.
