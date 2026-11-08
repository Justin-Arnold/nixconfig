# automation

automation is the lab's router between systems: a NixOS VM on the Proxmox
cluster that runs n8n. Events come in (GitHub's webhook deliveries, and
Alerta saying an alert opened) and n8n decides what they mean with plain
rules: answer, start a Paperclip routine, or raise an alert in Alerta. The point is that the mechanical part of
a job never costs a model run, and an agent is woken only where judgment adds
something.

It holds the GitHub webhook secret, the secrets of the Paperclip routines it
may start, an Alerta key of its own, and a Paperclip key of its own on the
researcher that it uses only to see whether a triage is open.

## At a glance

| | |
|---|---|
| VM | Proxmox, 4 vCPU (`x86-64-v2-AES`), 8 GB, 40 GB on `nas-shared`, MAC `02:01:18:00:00:0a`, address `10.0.0.155`, HA resource |
| n8n | `https://automation.servicestack.xyz` (n8n 2.39.6 from nixpkgs), SQLite in `/var/lib/n8n/.n8n` |
| GitHub deliveries | `https://intake.lab118.xyz/github`, passed over the tunnel to `/webhook/github` |
| Alerta's pushes | from Alerta's plugin on lab118-services, over the tunnel to `/webhook/alerta` |
| Login | `ssh automation` as `justin`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/automation.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | Nightly at 03:15, NFS share on the NAS, age-encrypted, Kuma push monitor |

The VM is bigger than n8n needs to run. n8n is unfree, so no binary cache has
it, and a switch that moves its version builds it on the VM from source.

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/automation/configuration.nix` | The host: users, SOPS, the Beszel agent, and the exposure assertions. |
| `hosts/automation/n8n.nix` | n8n's settings, its fixed UID, and the network fence around it. |
| `hosts/automation/endpoints.nix` | ACME (Porkbun DNS-01), nginx and its allow-lists. |
| `hosts/automation/backup.nix` | The NFS mount, what gets backed up, and the key fingerprint n8n writes before it starts. |
| `hosts/automation/n8n-credentials.json` | The n8n credentials, each field naming where its value is in SOPS. |
| `hosts/automation/workflows/` | One file per workflow, as n8n's public API takes it. |
| `hosts/automation/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `infra/terranix/hosts/automation.nix` | The VM, its storage, CPU type and HA resource. |
| `scripts/automation/n8n-apply.py` | Brings n8n's credentials and workflows in line with the repo. |
| `scripts/automation/post-install-check.sh` | Read-only health report: `ssh automation 'sudo bash -s' < scripts/automation/post-install-check.sh`. |
| `scripts/automation/tests/` | Its test, against a fake n8n, run by the `provisioning` check. |
| `hosts/lab118-services/public-endpoints.nix` | Where `intake.lab118.xyz/github` hands deliveries to the tunnel. |
| `modules/roles/notifications-stack/alerta-push/` | Alerta's plugin, which also tells n8n when an alert opens. |

## How it's reached

The name exists twice. In the LAN and over the road-warrior VPN, AdGuard
rewrites `automation.servicestack.xyz` to the VM, and nginx serves it with a
Let's Encrypt certificate from Porkbun DNS-01. From anywhere else the name
resolves to Pangolin, which asks for SSO and comes in through the home site's
Newt (`10.0.0.72`) like any LAN client. n8n's own login applies after either.

lab118-services resolves the name through lab DNS over the tunnel
(`labDomains`), so GitHub's deliveries and Kuma's check never meet Pangolin.

| Path | Who may use it | Goes to |
|---|---|---|
| `/webhook/github` | the tunnel (`10.118.0.1`) only, POST only | the `github` workflow |
| `/webhook/alerta` | the tunnel only, POST only, 16 KB at most | the `alerta` workflow |
| `/healthz` | LAN, VPN, the tunnel (Kuma) | n8n's health check |
| everything else | LAN (Pangolin included), VPN | n8n, `127.0.0.1:5678`: the UI, its API, the public API and the editor's test webhooks |
| unknown names, bare IP | nobody | no certificate, no content |

The firewall opens TCP 22, 80 and 443 and nothing else, and n8n listens on
127.0.0.1. The assertions fail the build if the tunnel can reach any other
path, if n8n listens anywhere else, or if a port opens, and
`.#checks.<system>.automation-exposure-guards` proves they fire.

### DNS and router settings this depends on

These live outside the repo:
- An OPNsense DHCP reservation of `10.0.0.155` for `02:01:18:00:00:0a`.
- An AdGuard rewrite for `automation.servicestack.xyz` to `10.0.0.155`.
- A `WG_LAB118` rule passing TCP 443 from `10.118.0.1` to `10.0.0.155`.
- Pangolin: a resource on the home site for `automation.servicestack.xyz`,
  targeting `https://10.0.0.155:443` with its TLS server name set to the same
  name, and SSO on.
- The nixconfig repository's webhook: payload URL
  `https://intake.lab118.xyz/github`, content type `application/json`, the
  secret from `github/webhook-secret`, SSL verification on, and the
  `Workflow runs` and `Pull requests` events.

## n8n

n8n runs from nixpkgs' module with these changes:
- A fixed user, `n8n` (UID 5678), instead of a dynamic one, so its data sits in
  `/var/lib/n8n` and the backup can read it as its owner.
- The encryption key for stored credentials comes from SOPS, so a rebuilt VM
  can read a restored database.
- Nothing calls home or pulls code in: telemetry, version checks, templates
  and community packages are off.
- n8n's MCP server access is off, and nodes can't read the service's
  environment. n8n won't load a node that runs code (Code, Function, AI
  Transform and LangChain's code nodes), reaches the host's files, git, SSH
  or FTP, or drives n8n's own API (`excludedNodes` in `n8n.nix`), so not even
  an edit in the UI can use one.

n8n reaches only loopback, the internet, `10.0.0.152:443` (Paperclip on the
agents VM: its routine triggers as `paperclip-triggers.servicestack.xyz` and
its API as `paperclip.servicestack.xyz`, both of which AdGuard rewrites to
it) and `10.118.0.1` (Alerta over the tunnel). Every other private range is denied in its unit, so a workflow that
holds a secret can't send it anywhere else in the lab. An assertion keeps
that list exact.

n8n logs "Failed to start Python task runner in internal mode" at every
start. Nothing here uses Python in a Code node, and the JavaScript runner
starts fine.

## Workflows as code

`scripts/automation/n8n-apply.py`, run from the Mac, makes n8n match the
repo. It's a dry run unless `--apply`, it never deletes anything, and it
reports what exists only in n8n. It uses the public API with the API key
from `n8n/api-key`.

Credentials come from `n8n-credentials.json`. Each field names a SOPS path,
and the script reads the value with sops and hands it straight to n8n,
without printing it. A field that isn't the secret, like the header name of
the Alerta key, is written `{"literal": "X-API-Key"}`; one that is can't be. A missing credential is created. n8n never shows a
stored value, and 2.39's public API refuses to change one (`PATCH
/credentials/{id}` answers 405), so an existing credential is left alone. To
change a secret, change it in SOPS, delete the credential in n8n's UI, and
apply again. Workflows find their credentials by name, so they follow the
new one.

Workflows come from `workflows/`, one file each, with exactly `name`,
`nodes`, `connections` and `settings`. A node names its credentials, and the
script fills in the ids n8n gave them. A URL that only SOPS has, like the
Fix CI trigger's, is written `{"sops": "paperclip-triggers/fix-ci/url"}` in a
parameter named `url`, and the script fills that in too; a SOPS path
anywhere else, or one not ending in `/url`, is refused. A missing workflow is created and
published. One whose nodes, connections or settings differ is put back and
stays published. Editing a workflow in the UI works until the next apply,
which undoes it.

The script refuses a workflow file that carries a credential's id or data, a
literal `Authorization` header, a literal value in a field named like a
secret, or any value it read from SOPS. `--check` runs the checks that need
neither n8n nor SOPS, and the `provisioning` flake check runs it on the repo's
files, so on every pull request.

Agents may propose workflows, so the script also keeps what one can reach to
short lists, written at the top of `n8n-apply.py`:

| What | Allowed |
|---|---|
| Node types | webhook, respond to webhook, if, filter, switch, wait, schedule trigger, HTTP request, crypto, set, split out, aggregate, merge, no-op |
| Hosts a url may name | `https://api.github.com/` and Alerta (`http://10.118.0.1:5000/`), or a Paperclip trigger's url from SOPS |
| SOPS paths a credential may read | `github/webhook-secret`, `alerta/n8n-key`, `paperclip/n8n-key`, `paperclip-triggers/<name>/secret` |
| Where each credential may go | the webhook secret only into a Crypto node; the Alerta key only to Alerta; a trigger's secret only to that trigger's url; the Paperclip key only in a GET of a routine's open issues |

A url is written out or comes from SOPS, never from an expression, and the
HTTP node's proxy and pagination options are refused, since either could
send a request somewhere else. Each HTTP credential also carries n8n's own
domain fence, `allowedHttpRequestDomains` and `allowedDomains`, which n8n
checks on every request and every redirect. Loosening any of this is a
change to `n8n-apply.py`, `n8n.nix` or `n8n-credentials.json` that Justin
reads, and infra's instructions say never to make it to get a workflow
through. A change to a credential, a url or a webhook path gets the
`sensitive` label.

`scripts/automation/tests/n8n-live-test.py`, run by hand on the Mac, starts a
scratch n8n with the host's excluded nodes, fakes GitHub, Alerta and
Paperclip, applies the repo's workflows and sends them GitHub's deliveries
and Alerta's pushes. The alerta workflow's waits are cut to seconds there,
and then to just over a minute, which n8n parks in its database the way it
parks the real ones (`--quick` leaves that part out, about three minutes).
It also checks that the domain fence holds, redirects included, and that a
Code node can't be published. n8n is unfree, so its build line is at the top of the
script.

The API key needs only these scopes: `credential:create`, `credential:list`,
`workflow:create`, `workflow:list`, `workflow:read`, `workflow:update` and
`workflow:activate`. n8n enforces a key's scopes, but without a licence its UI
may not offer the choice, and then the key can do anything the owner can.
That's why it lives only in SOPS and on the Mac, and the host never reads it.

## GitHub deliveries

GitHub posts to `intake.lab118.xyz/github`. nginx on lab118-services takes
POST only, rate-limits it, and passes it unchanged over the tunnel to
`https://automation.servicestack.xyz/webhook/github`, checking the VM's
certificate. It resolves the name when a delivery arrives, so a lab outage
fails only this path and never stops nginx starting.

The `github` workflow takes the raw body, computes its HMAC-SHA256 with the
`GitHub webhook secret` credential (n8n's Crypto node), and compares it with
`X-Hub-Signature-256`. Anything that doesn't match gets 401 before it goes
further, and a signed `ping` gets 200 with the hook's id. Then it routes,
with plain rules and no model:

| Event | When | What happens |
|---|---|---|
| `workflow_run` completed | `check.yml`, on an `agent/ci/*`, `agent/infra/*` or `agent/engineer/*` branch of nixconfig itself | 202, then the run is routed (below) |
| `pull_request` closed | the same branches | 202, then it clears that pull request's LandReady, CIStuck and RoutineFailed, if any are open |
| anything else | | 202 and nothing more |

A run is routed like this:
1. n8n finds the branch's open pull request through GitHub's public API. A
   run that isn't on the pull request's current head is dropped, so a late
   or redelivered event for an older commit does nothing.
2. **Green** raises LandReady.
3. **Failed or timed out** starts a Fix CI routine for the branch's agent:
   infra's for `agent/ci/*` and `agent/infra/*`, the engineer's own for
   `agent/engineer/*`. Before that, n8n counts the commits of the branch
   that went red, from GitHub's list of its `check.yml` runs, so re-runs
   count once. On the fourth it wakes nobody and raises CIStuck for you
   instead.
4. **Anything else**, like a cancelled run, does nothing.

LandReady, CIStuck and RoutineFailed go to Alerta with the `Alerta key`
credential (`X-API-Key`), from origin `n8n`, resource `nixconfig#<n>`, with
the pull request's link in `attributes.url`. LandReady is `informational` and
the other two `warning`, so they reach the phone with a link. The alert
intake below skips origin `n8n`, so the monitor never sees them.

Each Fix CI is a Paperclip routine webhook on the agents VM
(`paperclip-triggers.servicestack.xyz`), signed with its own trigger's
bearer credential. Its body is the repo and the number and nothing else, and
its `Idempotency-Key` is `check-run-<run id>-<attempt>`. Paperclip keeps
those keys for good, so nothing that repeats a run's routing starts a second
issue. Paperclip answers 202 even when it didn't start the routine, so n8n
reads the status it gives back, and anything but `issue_created` or
`coalesced` raises RoutineFailed. No text from GitHub reaches an alert or a
routine: only numbers, branch names checked against a pattern, and links.

GitHub doesn't retry a delivery that failed, so the same workflow sweeps
every 30 minutes. It lists nixconfig's open pull requests on agent branches,
reads the latest completed `check.yml` run on each one's head, and routes it
the same way. A sweep raises LandReady or CIStuck only if Alerta has no
alert of that kind for the pull request at all, so one you closed by hand
stays closed, and its Fix CI key is the same as the webhook's. Both paths
meet at one node, `Run`, and everything after it reads the run from there.

The calls to Alerta and Paperclip retry twice, and GitHub's once, 5 seconds
apart. One that still fails shows in n8n's executions, and the next sweep
tries again. n8n keeps only the last of two query parameters with one name,
so a repeated one, like Alerta's `status=open&status=ack`, is a single
parameter whose value is an array, sent with the HTTP node's "No Brackets"
array format.

## Alerts from Alerta

When an alert opens in Alerta (a new one, one reopening, or one changing
severity, but not a repeat), Alerta's plugin on lab118-services posts its id
to `https://automation.servicestack.xyz/webhook/alerta` over the tunnel. It
does that in the background with a 3-second timeout and drops any failure,
like its kick to the forwarder.

The push is only a hint. The `alerta` workflow answers 202, trusts nothing
in the body, and reads everything from Alerta with its own key:

1. It waits 3 minutes, so a burst becomes one batch, and an alert that clears
   in that time drops out. n8n parks a wait that long in its database.
2. It asks Paperclip whether the monitor is still on a triage, with a GET of
   the triage routine's `todo` and `in_progress` issues (the url
   `paperclip-apply.py` writes to `paperclip-triggers/triage/open/url`) and
   the `Paperclip read key`. While one is open, it looks again every 5
   minutes, six times, and then leaves it to the sweep.
3. It reads Alerta's open alerts in Homelab with their history, and keeps the
   ones the monitor should see:
   - severity critical, major, minor or warning;
   - not from `agent-watch`, `n8n` or `send-test-alert.sh`: the agents' own
     alerts, n8n's, and the end-to-end test script's;
   - not known to be harmless, which today means Kuma's test notification
     (origin `uptimekuma`, event `msg`);
   - not handed over since it last opened. A handed alert has an
     `n8nTriagedAt` attribute at or after its `receiveTime`, which Alerta
     moves when an alert opens, reopens or changes severity, and never on a
     repeat;
   - not flapping: three opens or severity changes in the last hour, with a
     triage already within that hour.
4. It starts the monitor's "Triage {{count}} lab alert(s)" routine through its
   webhook trigger, with the `Paperclip triage trigger` credential, sending
   the alerts' ids and how many there are and nothing else. The
   `Idempotency-Key` is a SHA-256 of the batch's `id@receiveTime` list and
   the UTC hour, so one batch starts once, and one Paperclip failed to start
   can go again an hour later.
5. On `issue_created`, `coalesced` or `skipped` (the same batch is already in
   a triage the monitor left blocked or in review), it sets `n8nTriagedAt`
   on each alert with one `PUT /_bulk/alerts/attributes`, the ids in the
   query. Alerta merges that one attribute and runs no plugin, so nothing is
   pushed back. Anything else raises IntakeFailed (warning, origin `n8n`,
   resource `n8n/intake`) and marks nothing.

A schedule every 30 minutes runs steps 2 to 5 without the wait, for pushes
lost while the tunnel or n8n was down.

The attribute in Alerta is all the state the intake keeps, so a rebuilt n8n
loses nothing. agent-watch on the agents VM raises IntakeStale when an alert
that should have gone has been open 15 minutes without it
(`docs/agents/REFERENCE.md`). Its rules are `agents.watch.intake`, and an
assertion keeps them the same as the workflow's `Eligible?` node, so the two
change together.

## Monitoring

Kuma watches the host over the tunnel, and the Beszel agent reports to the hub
on dashboard.

| Monitor | Check | Down means |
|---|---|---|
| `SVC / automation` | Keyword `"status":"ok"` at `https://automation.servicestack.xyz/healthz` | n8n, nginx or the VM is down (or the tunnel) |
| `JOB / automation backup` | push, 26 h heartbeat (`kuma/backup-push-url`) | the nightly backup failed or didn't run |

The check is a keyword one because the name resolves to Pangolin from outside
the lab, where a plain HTTP check would get a 200 from the wrong place.

## Secrets

`secrets/hosts/automation.yaml` is encrypted to the host's own age key and the
operator key, nothing else. On macOS, edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/automation.yaml`.

| Key | What |
|---|---|
| `n8n/encryption-key` | `openssl rand -hex 32`. Never change it; keep a copy in 1Password. |
| `n8n/api-key` | the owner's API key for `n8n-apply.py`, made in n8n's UI. The host never reads it. |
| `github/webhook-secret` | `openssl rand -hex 32`, also set on the repository's webhook |
| `alerta/n8n-key` | an Alerta API key with `read:alerts` and `write:alerts`, made with `alertad key` on lab118-services |
| `paperclip-triggers/fix-ci/url`, `.../secret` | infra's Fix CI trigger's URL and bearer secret, written by `paperclip-apply.py` when it makes the trigger |
| `paperclip-triggers/fix-ci-engineer/url`, `.../secret` | the engineer's Fix CI trigger's, the same way |
| `paperclip-triggers/triage/url`, `.../secret`, `.../open/url` | the monitor's triage trigger's, and the url of that routine's open issues, written by `paperclip-apply.py` |
| `paperclip/n8n-key` | n8n's own key on the researcher, made by `paperclip-agent-key.py n8n`, fenced to that one GET |
| `porkbun/api-key`, `porkbun/secret-api-key` | for DNS-01 |
| `beszel/agent-token` | the hub's universal token |
| `kuma/backup-push-url` | push monitor for backups |
| `root/console-password-hash` | `mkpasswd -m yescrypt` |

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`). Until the file exists
the real host fails to build with a message saying so.

## Backups

`roles.sqliteBackup` runs at 03:15 (plus up to 10 minutes). It snapshots
n8n's `database.sqlite` as its owner, checks it, packs it with the
fingerprint of the encryption key, encrypts the archive to the host and
operator keys, and writes it to `/mnt/automation-backups`. It keeps 30 days
(never fewer than 7 archives) and reports to `kuma/backup-push-url`. Set that
push monitor's heartbeat interval to 26 hours.

The export is `10.0.0.20:/mnt/Main/backups/automation-backups` on TrueNAS
(`automation.backup.nfsDevice`). The share only accepts the VM's address and
maps root to root.

n8n writes the key's fingerprint to `/var/lib/n8n/.encryption-key.sha256`
before every start, and a restore refuses an archive whose fingerprint
doesn't match. Workflows and credentials can also be put back from the repo
and SOPS with `n8n-apply.py`. What only the backup has is the execution
history and the owner account.

```sh
sudo systemctl start sqlite-backup     # a backup now
sudo sqlite-backup list                # archives, newest first
sudo sqlite-backup restore /mnt/automation-backups/automation-<time>.tar.zst.age
```

## Upgrading

n8n comes from nixpkgs, so it moves with `nix flake update`. Read its release
notes, take a backup, and switch; the VM builds the new version, which takes a
while. Migrations only go forward, so rolling back means the previous lock and
the pre-upgrade backup. Run `n8n-apply.py` afterwards to see that the
workflows still match.

## Known limits

- n8n compares the signature with an ordinary string comparison, not a
  constant-time one. Through nginx, the tunnel and n8n's own timing, that
  difference can't be measured from outside.
- GitHub doesn't retry a failed delivery, so one that arrives while the lab is
  down is lost until it's redelivered from the repository's webhook settings.
- n8n-apply.py can't tell whether a stored credential still matches SOPS.
- The pull request lookup goes to GitHub's API without a token, which allows
  60 requests an hour from the lab's address. A delivery costs one or two and
  a sweep one plus about three per open agent pull request, far more than CI
  finishes, but a burst of redeliveries could run into it.
- n8n looks for an open triage every 5 minutes, so an alert that opened
  behind one goes up to 5 minutes after it ends.
- Alerta's push doesn't retry. The sweep picks up what it lost within 30
  minutes, and agent-watch raises IntakeStale after 15.

## Related

- `docs/lab118-services/REFERENCE.md`: the intake host and the tunnel.
- `docs/agents/REFERENCE.md`: Paperclip, its routines, and the smoke test's
  `route` stage.
- `docs/dashboard/REFERENCE.md`: the same VM pattern, with Homarr and Beszel.
