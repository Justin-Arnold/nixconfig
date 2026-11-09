# inference

inference is the lab's GPU host: a NixOS VM on proxmox2 with the RTX 3090
passed through. It serves one language model, under the name `local`, to
everything in the lab that needs one, and it does the speech side of Home
Assistant's voice assistant.

Its clients are Home Assistant and the Mac, for tests and ad-hoc use. Home
Assistant's voice assistant uses it to understand commands and answer. The
agents, Paperclip and the concierge all run on cloud models; the researcher
and the monitor used `local` until November 2026. Other uses come back case
by case, each as a client with its own key.

It holds no credentials but its own: the clients' keys, its certificate's DNS
key and the Beszel token. Nothing a client sends is stored on it.

## At a glance

| | |
|---|---|
| VM | Proxmox, 16 vCPU (`host`), 64 GB, 300 GB on `local-lvm` on `proxmox2`, q35, RTX 3090 passed through (mapping `gtx3090`), MAC `02:01:18:00:00:09`, no HA |
| Address | `10.0.0.63` (DHCP reservation) |
| Name | `inference.servicestack.xyz`, LAN and VPN only, HTTPS only |
| Model server | llama.cpp's `llama-server` b9608 (CUDA, sm_86), as `inference`, on `127.0.0.1:8080` |
| Model | `qwen3.6-35b-a3b` (Qwen3.6-35B-A3B, Unsloth's UD-IQ4_XS), served as `local`, 2 slots of 64K tokens |
| Voice | Whisper (`distil-large-v3`, on the GPU, port 10300) and Piper (`en_US-lessac-medium`, CPU, port 10200) for Home Assistant |
| Login | `ssh inference` as `justin`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/inference.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | none; the models download again and nothing else is kept |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/inference/configuration.nix` | The host: SOPS, the active model, the Beszel agent, and the exposure assertions. |
| `hosts/inference/models.nix` | The models it can serve, each pinned to a Hugging Face commit and a sha256. |
| `hosts/inference/endpoints.nix` | nginx: the certificate, the client keys, the connection limits. |
| `hosts/inference/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `modules/roles/inference.nix` | llama-server's unit, the model download and the flags it refuses. |
| `modules/roles/nvidia-gpu.nix` | The NVIDIA driver, headless. |
| `modules/roles/ai-voice.nix` | Whisper and Piper. |
| `infra/terranix/hosts/inference.nix` | The VM, its node and the GPU passthrough. |
| `scripts/inference/post-install-check.sh` | Read-only health report. |

## How it's reached

In the LAN and over the VPN, AdGuard rewrites `inference.servicestack.xyz`
to the VM, and nginx serves it with a Let's Encrypt certificate from Porkbun
DNS-01. There's no Pangolin resource. The Newt address is refused in every
location, so nothing from the Internet comes in that way.

| Path | Who may use it | Goes to |
|---|---|---|
| `POST /v1/chat/completions` | LAN and VPN, with a client key | the model |
| `GET /v1/models` | LAN and VPN, with a client key | the model's name, `local` |
| `GET /health` | LAN, VPN, the tunnel (Kuma) | whether the model is loaded |
| anything else | nobody (404) | |
| unknown names, bare IP | nobody | no certificate, no content |

That leaves llama-server's other endpoints unreachable: `/props`, `/slots`,
`/completion`, the Anthropic and Responses APIs, model loading and the web
UI. The server itself turns off `/slots`, `/props` changes and the web UI as
well.

The firewall opens TCP 22, 443, 10200 and 10300 and nothing else. Whisper and
Piper on 10200 and 10300 have no authentication, as Home Assistant expects.
The assertions in `configuration.nix`, `endpoints.nix` and the role fail the
build if any of this changes, and `.#checks.<system>.inference-exposure-guards`
proves they fire.

### DNS and router settings this depends on

These live outside the repo:
- An AdGuard rewrite for `inference.servicestack.xyz` to `10.0.0.63`.
- An OPNsense DHCP reservation for `02:01:18:00:00:09` at `10.0.0.63`.
- A `WG_LAB118` rule passing TCP 443 from `10.118.0.1` to the VM, for Kuma's
  check. lab118-services resolves the name through lab DNS over the tunnel
  (`labDomains` in `hosts/lab118-services/configuration.nix`), since there's
  no public record for it.
- The PCI resource mapping `gtx3090` on proxmox2.

## Clients and keys

Every client has its own key, `inference/keys/<client>` in SOPS, sent as
`Authorization: Bearer <key>`. nginx turns the header into the client's name
from a file SOPS renders when the host activates, so no key is in the nix
store, and it removes the header before the request reaches llama-server. A
request without a known key gets a 401.

| Client | Key | Uses |
|---|---|---|
| `ha` | `inference/keys/ha`, entered in Home Assistant's llama.cpp integration | the voice assistant |
| `mac` | `inference/keys/mac`, read from SOPS when it's needed | the model test and ad-hoc use |

A new client is a name in `clients` in `endpoints.nix` and a key in SOPS. A
work environment would be one more client, with its own key and addresses.

The server has two slots, one request each. Two connection limits keep one
of them for voice: every client except `ha` shares a pool of one, and each
key gets at most two at a time, so Home Assistant can use both. A request
over a limit gets a 429 straight away (nginx can't queue). The access
log, `/var/log/nginx/inference.log`, has a line per request with the client,
status and timings.

## The model server

llama-server runs one model, chosen by `roles.inference.active`, and answers
to the name `local` whatever the model is. Changing the model is a change to
`active` (and a pinned entry in `models.nix`); no client changes.

Each of the two slots has 64K tokens of context: room for Home Assistant's
prompt, which lists every exposed entity, and the conversation so far. Two
slots rather than four also mean Home Assistant's long, unchanging system
prompt usually stays cached in one, so a voice request only reads what's
new. The KV cache is q8_0 (half of f16, with no noticeable loss), flash
attention is on and every layer is on the GPU. It starts with `--fit off`, so
a model that doesn't fit beside Whisper fails to start instead of quietly
getting less context or moving layers to the CPU. Context shift is off, so a
request over 64K is refused rather than having its start cut off.

The server has no network of its own (`IPAddressDeny=any`, loopback only),
runs as the `inference` user with the same hardening as nixpkgs' llama-cpp
module, and restarts 10 seconds after a crash. Whisper starts first, so the
model's memory is sized against what's left on the card.

Each model's defaults suit voice: Home Assistant can't ask for anything, and
voice wants a quick answer. So gpt-oss-20b reasons at low effort, and Gemma
and Qwen don't think at all unless asked. A client that wants more reasoning
asks for it per request in `chat_template_kwargs`:
`reasoning_effort` for gpt-oss, `enable_thinking` for Gemma and Qwen. A
client can send both, since a template ignores the one it doesn't use.

### Models it can serve

These are in `hosts/inference/models.nix`, each pinned to an upload from
before llama.cpp b9608 came out, so the build is known to load them. Every
one fits four 64K slots beside Whisper, which takes 2,112 MiB, so two leave
room to spare. The figures below were measured with four.

| Model | File | llama-server on the card |
|---|---|---|
| `gpt-oss-20b` | ggml-org's MXFP4, 12.1 GB | 15,156 MiB |
| `gemma-4-26b-a4b` | Unsloth's UD-Q4_K_XL, 17.0 GB | 21,014 MiB |
| `qwen3.6-35b-a3b` | Unsloth's UD-IQ4_XS, 17.7 GB | 20,288 MiB |

Gemma's cache is small because most of its layers only look at the last 1024
tokens. Qwen's is small because three of every four layers are linear
attention. Qwen at Q4_K_M (20.4 GB) doesn't fit beside Whisper, hence IQ4_XS.

`scripts/inference/model-test.py` decides which one is `active`. It runs from
the Mac with the `mac` key against whichever model is served, and covers tool
calls, summaries, alert triage, background review, voice latency alone and
under load, the 64K refusal, reasoning overrides, throughput and the canary.
The tool calls use the researcher's real tools: `memory`, and Hermes'
on-demand bridge (`tool_search`, `tool_describe`, `tool_call`) to 33
Paperclip tools, `session_search` and `todo_list`, on three Paperclip issue
tasks. Its results files (`model-test-*.json`) are ignored by git.

### How the model was chosen

The test ran against each model on 4 November 2026, five runs of each
scenario:

| | `gpt-oss-20b` | `gemma-4-26b-a4b` | `qwen3.6-35b-a3b` |
|---|---|---|---|
| Agent tasks right | 3/5 | 4/5 | 5/5 |
| Tool calls valid | 83% | 100% | 100% |
| Summary with every fact | 3/5 | 4/5 | 5/5 |
| Alert triage | 5/5 | 5/5 | 4/5 |
| Background review's decision | 4/5 | 5/5 | 5/5 |
| Voice, first token alone | 0.20 s | 0.13 s | 0.15 s |
| Voice behind a 50K-token prompt | 11.3 s | 14.8 s | 16.6 s |
| Generating, one request | 206 tokens/s | 127 tokens/s | 131 tokens/s |
| Reading a prompt, one request | 1,184 tokens/s | 1,265 tokens/s | 984 tokens/s |

Qwen was the only one to get every agent task right, and it's `active`. The
test was written while the researcher ran here, so it weighs agent work over
voice; a model chosen for voice alone is still to be picked.
gpt-oss guessed argument names instead of looking them up, and in both
recall runs it never searched its past sessions and made up a time instead.
In an earlier run it said it had posted a comment it hadn't. Gemma's one
miss was a loop: it marked an issue done three times and never commented.
Qwen's triage miss was one run that said a full, failing backup disk didn't
need a human.

All three failed voice under load the same way, which is llama-server's
batching rather than the models (see Known limits). And all three ignored a
`reasoning_effort` at the top of a request: llama-server only reads it, and
`enable_thinking`, from `chat_template_kwargs`.

Gemma and Qwen sometimes batch two Paperclip calls into one `tool_call`, as
the tool's description suggests, and Hermes turns the batch away because it
only batches connector tools. Both retried one call at a time; it costs a
turn.

### Model files

A model is one GGUF file, or the parts of a split one, from a Hugging Face
URL pinned to a commit, with its sha256 (Hugging Face shows it as the LFS
oid). `inference-models.service` downloads the active model's files into
`/var/lib/inference/models/<model>/` before the server starts, resuming a
broken download, and refuses a file whose hash doesn't match. The files never
enter the nix store, so a deploy doesn't copy them. Switching to a new model
for the first time waits for its download, which is 12 to 20 GB.

Files of models no longer listed stay on disk until they're deleted by hand.

### What isn't kept

Nothing a client sends is written to disk:
- nginx keeps request bodies in memory (the body buffer is as large as the
  largest body allowed) and streams answers through without buffering them.
- The access log has no bodies and no query strings.
- llama-server keeps no prompt logs and no slot files; its prompt cache is in
  memory.
- There's no swap, and core dumps aren't stored, since one would hold
  prompts.

The post-install check proves it after a test: given the canary string the
test sent, it searches the journal, `/var/log`, `/var/cache`, `/var/lib` and
the temp directories, and should find nothing.

## Home Assistant

Home Assistant uses its llama.cpp integration (Home Assistant 2026.8 and
later) with the base URL `https://inference.servicestack.xyz/v1`, the `ha`
key and the model `local`, as the conversation agent of its voice pipeline.
Its speech to text is Whisper at `10.0.0.63:10300` and its text to speech is
Piper at `10.0.0.63:10200`, through the Wyoming integration.

## Monitoring

Beszel's agent reports the host and the GPU, Homarr's tile pings `/health`
from the dashboard VM, and Kuma watches it over the tunnel:

| Monitor | Check | Down means |
|---|---|---|
| `SVC / inference` | HTTP keyword on `https://inference.servicestack.xyz/health`, expect `ok` | the model isn't loaded, nginx or the VM is down (or the tunnel) |

## Secrets

`secrets/hosts/inference.yaml` is encrypted to the host's own age key and the
operator key, nothing else. On macOS, edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/inference.yaml`.

| Key | What |
|---|---|
| `root/console-password-hash` | `mkpasswd -m yescrypt` |
| `beszel/agent-token` | the hub's universal token |
| `porkbun/api-key`, `porkbun/secret-api-key` | for DNS-01 |
| `inference/keys/ha`, `inference/keys/mac` | `openssl rand -hex 32` each, the clients' keys |

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`). Until
`secrets/hosts/inference.yaml` exists, the real host fails to build with a
message saying so.

## Operations

```sh
sudo systemctl restart llama-server
sudo journalctl -u llama-server -u inference-models -n 100
nvidia-smi
```

Rebuilding the VM is `nix run .#provision -- inference` with
`HOST_AGE_KEY_FILE` and `SSH_PRIVATE_KEY_PATH` set. Nothing needs restoring:
the active model downloads again. llama.cpp's CUDA build has no binary cache,
so the first switch, and any after a llama.cpp update, compiles it on the VM,
which takes a while.

During a rebuild the NixOS installer asks DHCP for an address with a
different client identifier from the bootstrap template's, so OPNsense
answers it from the pool instead of the reservation, and `provision` waits on
`10.0.0.63` with nobody there. Adding the address by hand on the VM's console
(`ip addr add 10.0.0.63/24 dev ens18`) lets it carry on. The installed system
gets the reservation as usual.

Rotating a client's key means a new value in SOPS here and at the client,
switched close together; the old key stops working at once.

## Known limits

- One model at a time. Switching models drops every client, voice included,
  for as long as the new model takes to load (and to download, the first
  time).
- A long new prompt holds up every other request until it's read in.
  llama-server fills each batch from its slots in order, and the first one
  with a prompt to read takes the whole batch. In the model test, voice
  waited 11 to 17 seconds behind a 50K-token prompt, on every model. With the
  agents gone, only a long prompt from the Mac can do that now; a slot kept
  free for voice doesn't help, only a change to llama-server's batching would.
- The VM can't move: it's tied to proxmox2, where the card is.
- Whisper and Piper are open to the whole LAN with no authentication, and
  ports Podman publishes don't go through the host firewall.
- llama.cpp b9608 predates some 2026 models; one that needs a newer build
  means overriding the package.

## Related

- `docs/agents/REFERENCE.md`: the Hermes agents, which used to be a client.
- `docs/dashboard/REFERENCE.md`: Homarr and Beszel.
