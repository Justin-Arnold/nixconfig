# home-assistant

Fresh Home Assistant Core on NixOS, on a dedicated terranix VM. This is not
HAOS: there is no Supervisor/add-on store. Nothing is migrated from VM 135
or LXC 111, and neither guest is touched by this configuration.

## Design and boundaries

Justin selected `home-assistant` and the candidate network radio stack in
LAB-156 (interactions 6ce75c53 and 47c1aa99). These are design choices, not
purchases, possession of hardware, pairing results or deployment approvals.
The VM defaults to proxmox4 with an automatically allocated ID, 4 vCPU,
8 GiB RAM and 64 GiB disk. Disk and cloud-init are on `nas-shared`; the
CPU model is `x86-64-v2-AES`. No USB or PCI devices pass through, and the
shared VM helper is unchanged. Template 9999 on proxmox8 follows the current
automation pattern. Confirm template/storage compatibility in the eventual
approved plan; automation's historical fixed-ID workaround is not copied.

The planned MAC is `02:01:18:00:00:0b`. Address assignment remains DHCP;
no new fixed address or reservation is claimed here. The hostname already
resolved to `home-assistant.internal` / 10.0.0.81 during read-only discovery
on 2026-11-08, and the public FQDN resolved to 5.161.94.68. Do not switch
using that name until Justin has separately approved and verified the fresh
VM's DHCP/DNS mapping. No old-guest address is assigned by this PR.

## Network radios and integrations

The design targets one SMLIGHT SLZB-06 (CC2652P) on local wired Ethernet/PoE
for ZHA, a separate Apple TV 4K third-generation **Wi-Fi + Ethernet** model
as Thread border router, and an Olimex ESP32-PoE-ISO-EA running ESPHome
Bluetooth proxy for BLE. A different already-owned Thread border router
requires compatibility confirmation, not an assumption of ownership.
Zigbee and Thread are separate networks/radio roles. Z-Wave was not selected.
Wi-Fi Matter devices do not require a Thread border router. BLE proxy count
and placement require real coverage testing; a BLE proxy is not itself a
Thread border router or a general substitute for Matter BLE commissioning.

ZHA's network serial endpoint, ESPHome encrypted native API credentials and
Thread/mobile commissioning are configured during fresh onboarding, never
with pairing codes or tokens in git. Use the SMLIGHT's wired local Ethernet,
not Wi-Fi/WAN/VPN serial transport. Its exact address, firmware and serial
port must be verified on the device. The Apple Thread network and mobile
commissioning prerequisites must be checked before claiming Matter works.
No hardware procurement or flashing is authorized by this reference.

The package includes ZHA, Matter, Thread, ESPHome, Bluetooth, HomeKit Bridge,
Wyoming and the upstream llama.cpp conversation integration. There
are no custom integrations. HomeKit Bridge has no entity filters, exposing
all supported entities (subject to upstream bridge capacity/limitations);
additional bridges for a larger inventory require a reviewed change.
HA integrations and their tokens, dashboards, devices and pairing information
remain mutable `.storage` state, not fully declarative Nix configuration.

## Endpoints and exposure

The intended URL is `https://home-assistant.servicestack.xyz`. nginx uses
Porkbun DNS-01 ACME and accepts the UI/API/WebSocket only from LAN
10.0.0.0/24 and VPN 10.10.10.0/24. It explicitly denies Newt 10.0.0.72;
there is no public/Pangolin resource in this change. Unknown names/bare IP
receive no content. HA HTTP binds to 127.0.0.1:8123 with only loopback trusted
as reverse proxy. Matter's unauthenticated WebSocket binds to 127.0.0.1:5580.
Neither backend port is opened by the firewall.

HomeKit TCP 21063 is LAN-only. Discovery UDP 5353 and Matter UDP 5540 are
limited to the VM's `ens18` LAN interface and local LAN IPv4 or IPv6
link-local/ULA sources. IPv6, multicast and reachability between the host,
border router, commissioning phone and devices must actually work; opening
these host rules is not proof that the router/switch supports them. No mDNS
reflector is enabled. The Web UI, SSH and TLS ports are separate from radio
discovery; do not broadly open ephemeral ports to make pairing succeed.
Beszel connects outbound only, using the existing role.

## Voice

Inference remains separate. Source verification found `ha` in its client
list and `voiceClient = "ha"`; Whisper is TCP 10300 and Piper TCP 10200 on
inference (documented address 10.0.0.63). Fresh onboarding adds Wyoming
endpoints for those services. The upstream `llama_cpp` integration accepts a
base URL and API key (verified in the pinned HA 2026.10.4 config flow).
Conversation uses `https://inference.servicestack.xyz/v1`, model `local`, with
the existing `inference/keys/ha` credential handled securely by Justin. Its
tool schema and Assist behavior still need live acceptance; no end-to-end
result is claimed here.
No key is read/copied by this change. Satellites remain unspecified, not
"none". No inference redesign or prefill-latency work is included.

## Secrets and provisioning contract

Required encrypted file: `secrets/hosts/home-assistant.yaml`, with a dedicated
host age identity installed at `/var/lib/sops-nix/key.txt`. Required entries:
`root/console-password-hash` (console-only password hash),
`porkbun/api-key`, `porkbun/secret-api-key` (DNS-01),
`beszel/agent-token` (outbound agent), and `kuma/backup-push-url` (backup job).
These are declarations only. The encrypted file/recipient must be added by
Justin securely under exact board approval; no placeholders or real secret
values are committed. Missing-file validation remains fail-closed. The
separate `eval-test.nix` is test-only and never imported by the deployed host.
The inference HA credential stays under its existing SOPS path; onboarding
handles it securely outside git.

The repository exports `nix run .#plan -- home-assistant`,
`HOST_AGE_KEY_FILE=<host-key-file> nix run .#provision -- home-assistant`, and
`nix run .#switch -- home-assistant`. These are operator interfaces, not
commands run by Infra. Provision includes installation; the fresh DHCP/DNS
mapping must be verified before any later switch. State/backend/operator
credentials and the dedicated host key are existing provisioning prerequisites.
DNS/DHCP, NAS export creation, monitoring registration, purchases, secrets,
provisioning and switches each require the applicable exact-scope board
approval; Reviewer approval does not replace it. Step 4 owns the live checklist.

## Backup and recovery model

The proposed NAS export is
`10.0.0.20:/mnt/Main/backups/home-assistant-backups`, mounted on demand at
`/mnt/home-assistant-backups`. It must be created/authorized by Justin; its
existence is not claimed. `roles.sqliteBackup` makes an age-encrypted archive,
reads it back and checks SQLite integrity. Retention is 30 days with at least
7 archives. The operator public age recipient provides recovery off-host.
The host identity itself is not archived; retain it securely outside the VM.

The backup job first refuses absent recorder, HA `.storage` or Matter state/cache,
then briefly stops HA and Matter for the complete snapshot/archive
operation and restarts them even if it fails. This intentional maintenance
outage makes all mutable file copies mutually consistent. The recorder DB
lives outside the config tree at `/var/lib/home-assistant-recorder/recorder.sqlite`
and is snapshotted with SQLite `.backup`, not copied live. The entire
`/var/lib/hass` tree is included (including `.storage`, Zigbee database,
HomeKit pairing/configuration, automations, scripts, media and other files).
Matter's actual DynamicUser state directory `/var/lib/private/matter-server`
and its private cache are included, not just the symlinks in `/var/lib`.
Backups contain credentials/pairing material, so access must remain restricted
and encrypted. Kuma push monitors report backup success/failure, not recovery
proof. A missing recorder database before first onboarding fails the backup
rather than claiming success.

The existing `sqlite-backup restore <archive>` tool stops both applications,
validates/restores the recorder snapshot and file trees and restarts them,
keeping replaced files. This is a new-system recovery interface, not an
old-system migration. Restore only with the matching configuration/software
version and secured keys. Restoring a database migrated by a newer HA into
an older generation is not safe; restore a matching pre-upgrade archive as
well as the Nix generation. NixOS generation rollback alone never reverses
HA/Matter database/schema changes. A live restore drill and device/voice
acceptance remain step-4 requirements; no recovery has been exercised live.

## Update model

Automatic update capability is the repository's reviewed dependency-PR/CI
flow, followed by a separately authorized operator switch of the merged
revision. No timer autonomously updates nixpkgs, switches or reboots this
host. Before each approved upgrade, take/verify a backup at the current
version and preserve the generation/commit and archive together. Run checks
on the PR; database migrations occur on service start. Future automatic live
switches would need an explicit separately approved policy. The preference
for automatic updates is not that policy.

## Source trail and verification limits

Source inspection uses the repository's current flake.lock, not claims from
historical nixpkgs bugs. The selected nixpkgs exposes `python-matter-server`
as an application that adds its `server` optional dependencies; the raw Python
library alone does not. The host uses that application unchanged. Runtime
package/config checks and exposure regression tests belong to this PR's check
results, not assumed success from these source declarations.

Hardware sources retrieved 2026-11-08:
https://smlight.tech/product/slzb-06/ ;
https://www.home-assistant.io/integrations/zha/ ;
https://www.home-assistant.io/integrations/thread/ ;
https://esphome.io/components/bluetooth_proxy/ .
Actual pairing, service health, IPv6/mDNS routing, BLE coverage, NAS writes,
ACME issuance, DHCP/DNS and fresh voice/HomeKit onboarding await Justin in
step 4. This reference describes the design, not a live runbook or test result.
