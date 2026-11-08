# How the agents and the alerts fit together

The agent platform and the notification stack are written up host by host in
each `docs/<host>/REFERENCE.md`. This page is the picture across all of them:
who starts what, what crosses between hosts, and where each thing ends up,
including your phone. The details, settings and limits stay in the reference
docs, which each section points to.

Two rules shape every diagram here. Work starts from an event or from you,
not from a model checking in on a timer, and plain code (n8n, agent-watch,
lab-health) does the routing so a model only runs where judgment helps. And
no agent changes a running system: they read, they open pull requests, and
they ask. You land, switch and destroy.

## The map

Everything at once, by where it runs. Solid arrows carry work or alerts,
dotted ones only read. The sections after this zoom into each path.

```mermaid
flowchart TB
  you["You: Paperclip UI, OpenClaw WebChat,<br/>Telegram and Discord DMs, the ntfy app"]

  subgraph agentsvm["agents VM"]
    paperclip["Paperclip: issues, routines, approvals"]
    hermes["Six Hermes agents: coordinator, engineer,<br/>researcher, reviewer, infra, monitor"]
    services["Plain services: paperclip-events,<br/>agent-watch, board-bridge, lab-health"]
  end

  subgraph vms["Other lab VMs"]
    concierge["openclaw: the concierge"]
    workbench["workbench: the agents' terminals"]
    inference["inference: the local model"]
    n8n["automation: n8n"]
  end

  subgraph lab118["lab118-services VPS"]
    kuma["Uptime Kuma"]
    alerta["Alerta"]
    delivery["Forwarder, Apprise, ntfy"]
  end

  github["GitHub: repos and Actions"]
  observed["Proxmox and Beszel"]

  you -->|"issues and answers"| paperclip
  you -->|"chat"| concierge
  concierge -->|"files issues"| paperclip
  paperclip <-->|"wakes, tool calls"| hermes
  hermes -->|"model calls"| inference
  hermes -->|"SSH"| workbench
  workbench -->|"agent branches and PRs"| github
  hermes -.->|"read-only"| observed
  hermes -.->|"read-only"| lab118
  paperclip -->|"live events"| services
  services -->|"alerts"| alerta
  services <-->|"DMs and your answers"| you
  github -->|"CI results"| n8n
  n8n -->|"routine webhooks"| paperclip
  n8n -->|"alerts"| alerta
  kuma -->|"alerts"| alerta
  alerta -->|"opened alerts"| n8n
  alerta --> delivery
  delivery -->|"push"| you
```

The lab reaches lab118-services only over the WireGuard tunnel
(`10.118.0.1/30`), and lab118 reaches back only to the HTTPS of a few VMs
(`docs/lab118-services/REFERENCE.md`). The agents' egress filter lets each
agent reach the internet and only the lab addresses it needs
(`docs/agents/REFERENCE.md`).

## From a request to a landed change

You, or the concierge on your behalf, file an issue. The coordinator splits
it and gives each piece to the agent for it, with the reviewer as a review
stage. Code is written on workbench and leaves as a pull request on an
`agent/` branch, which is the only kind of branch the agents' GitHub account
can push.

```mermaid
sequenceDiagram
  autonumber
  actor You
  participant PC as Paperclip
  participant Co as Coordinator
  participant Ag as Engineer or infra
  participant GH as GitHub
  participant N8 as n8n
  participant Rv as Reviewer

  You->>PC: an issue, yours or the concierge's
  PC->>Co: wake
  Co->>PC: sub-issues with a review stage
  PC->>Ag: wake
  Ag->>GH: from workbench: push, open a PR
  GH->>N8: check.yml finished
  alt green
    N8->>You: LandReady on the phone
  else red, up to three commits
    N8->>PC: start Fix CI
  else red a fourth time
    N8->>You: CIStuck on the phone
  end
  Ag->>PC: done
  PC->>Rv: the review stage
  Rv->>GH: review comments
  Rv->>PC: approved, or sent back
  Note over Ag,Rv: no agent can merge, switch or destroy
  You->>GH: land-pr.sh, green checks only
  You->>You: switch the hosts it touches
  GH->>N8: PR closed
  N8->>N8: clear its alerts
```

Each step's details: the coordinator and the review gate in
`docs/agents/REFERENCE.md`, workbench and `land-pr.sh` in
`docs/workbench/REFERENCE.md`, and n8n's routing in
`docs/automation/REFERENCE.md`.

## When an agent needs you

An agent never asks in a comment, which reaches nobody. It asks in Paperclip,
sets its issue blocked and ends its run. Within seconds you hear about it on
three channels, and an answer on any of them, or in Paperclip itself, wakes
the agent where it stopped.

```mermaid
flowchart TD
  ask["An agent asks in Paperclip:<br/>a question, a confirmation or an approval"]
  blocked["It sets its issue blocked and ends its run"]
  events["paperclip-events hears it at once"]
  watch["agent-watch"]
  bridge["board-bridge"]
  alerta["Alerta"]
  ntfy["ntfy on the phone"]
  tg["Telegram DM"]
  dc["Discord DM"]
  ui["Paperclip UI"]
  answered["Paperclip records your answer"]
  wake["The agent wakes on the same issue<br/>and carries on"]
  clear["The alert clears and<br/>every DM shows it answered"]

  ask --> blocked --> events
  events --> watch
  events --> bridge
  watch -->|"WaitingOnYou or ApprovalWaiting,<br/>with a link"| alerta --> ntfy
  bridge -->|"the options as buttons"| tg
  bridge -->|"the options as buttons"| dc
  ntfy -->|"tap the link"| ui
  ui -->|"answer there"| answered
  tg -->|"press a button"| answered
  dc -->|"press a button"| answered
  answered --> wake
  answered --> clear
```

board-bridge answers as the board only for the presses and replies of your
own two accounts, in a DM. Rejecting an approval doesn't wake its agent;
approving does. See `docs/agents/REFERENCE.md`, "Asking you" and "Telegram
and Discord".

## An alert's path

Everything that goes wrong in the lab ends up in Alerta on lab118-services.
From there, one path takes it to your phone and another hands it to the
monitor agent to look into. Alerta's push plugin starts both, so neither
waits on a timer.

```mermaid
flowchart TB
  subgraph producers["Producers"]
    kuma["Uptime Kuma: SVC, LAB<br/>and JOB monitors"]
    pushes["Push heartbeats: backups,<br/>Beszel hub, router, agent-watch"]
    watch["agent-watch"]
    n8nraised["n8n: LandReady, CIStuck,<br/>RoutineFailed, IntakeFailed"]
    tests["send-test-alert.sh and the smoke test"]
  end

  pushes -->|"intake.lab118.xyz/api/push"| kuma
  kuma -->|"on a change of state"| alerta["Alerta"]
  watch -->|"over the tunnel"| alerta
  n8nraised -->|"over the tunnel"| alerta
  tests --> alerta
  alerta --> plugin["Push plugin"]

  plugin -->|"kick"| fwd{"Forwarder: did its severity,<br/>status or text change?"}
  fwd -->|"yes"| apprise["Apprise"] --> ntfy["ntfy.lab118.xyz"]
  ntfy -->|"message id only"| ntfysh["ntfy.sh"] --> apns["APNs wakes the phone"]
  apns --> phone["The ntfy app fetches the message<br/>from ntfy.lab118.xyz"]

  plugin -->|"new, reopened or a new severity:<br/>its id, over the tunnel"| settle["n8n waits 3 minutes"]
  sweep["n8n, every 30 minutes"] --> open
  settle --> open{"A triage still open?"}
  open -->|"yes, look again in 5 minutes"| open
  open -->|"no"| eligible{"Warning or worse, not the agents',<br/>n8n's or a test's, not handed over,<br/>not flapping?"}
  eligible -->|"none"| nothing["Nothing more"]
  eligible -->|"some"| triage["The monitor's triage routine:<br/>alert ids and a count only"]
  triage -->|"started"| mark["n8nTriagedAt set on each alert"]
  triage -->|"didn't start"| failed["IntakeFailed"]
  triage --> monitor["The monitor reads each alert and the lab,<br/>comments, and sets done or asks you"]
```

The text of an alert never reaches ntfy.sh, only a message id, and no alert
text reaches Paperclip, only Alerta's ids. Kuma's own test notification and
alerts from the agents, n8n and the test script are kept from the monitor,
and agent-watch raises IntakeStale when an alert that should have gone
hasn't after 15 minutes. See `docs/lab118-services/REFERENCE.md`, Delivery,
and `docs/automation/REFERENCE.md`, "Alerts from Alerta".

## CI on an agent branch

GitHub runs `check.yml` on every pull request. n8n reads the result and
decides, with plain rules, whether you hear that it's ready or an agent is
woken to fix it. GitHub never retries a delivery that failed, so the same
rules also run as a sweep every 30 minutes.

```mermaid
flowchart TD
  pr["A pull request on agent/ci/,<br/>agent/infra/ or agent/engineer/"] --> check["check.yml on GitHub's runners"]
  flake["update-flake-lock.yml on Mondays<br/>opens agent/ci/flake-update-date"] --> check
  check -->|"workflow_run webhook"| intake["intake.lab118.xyz/github,<br/>then over the tunnel"]
  intake --> signed{"Signed with the<br/>webhook secret?"}
  signed -->|"no"| refused["401"]
  signed -->|"yes"| branch{"check.yml, on an<br/>agent branch?"}
  branch -->|"no"| ignored["202 and nothing more"]
  branch -->|"yes"| run["Run"]
  sweep["Every 30 minutes: open agent pull requests<br/>and the latest run on each head"] --> run
  run --> head{"On the pull request's<br/>current head?"}
  head -->|"no"| dropped["Dropped"]
  head -->|"yes"| result{"Result"}
  result -->|"green"| land["LandReady on the phone, with the link"]
  result -->|"red or timed out"| cap{"Three red commits<br/>or fewer?"}
  cap -->|"no"| stuck["CIStuck on the phone, nobody woken"]
  cap -->|"yes"| who{"Branch"}
  who -->|"agent/engineer/"| fixe["The engineer's Fix CI"]
  who -->|"agent/ci/ or agent/infra/"| fixi["Infra's Fix CI"]
  fixe --> started{"Did Paperclip start it?"}
  fixi --> started
  started -->|"no"| routinefailed["RoutineFailed on the phone"]
  closed["The pull request closes"] --> cleared["n8n clears its LandReady,<br/>CIStuck and RoutineFailed"]
```

Fix CI is keyed on the run and its attempt, so nothing that repeats a run's
routing starts a second issue. See `docs/automation/REFERENCE.md`, "GitHub
deliveries".

## The morning check

At 07:00 lab-health reads the lab in code, with fixed thresholds, and wakes
the monitor only when something is wrong, with codes rather than text. A
quiet morning runs no model at all.

```mermaid
flowchart TD
  timer["07:00 New York time"] --> lh["lab-health reads Proxmox, Beszel,<br/>Kuma and Alerta, read-only"]
  lh --> codes["Fixed codes: node-offline, storage-full, disk-full,<br/>services-failed, monitor-down, alert-stale and others"]
  codes --> any{"Any findings?"}
  any -->|"no"| quiet["Nothing starts"]
  any -->|"yes"| routine["Look into N lab finding(s),<br/>the codes only, once a day"]
  routine --> monitor["The monitor checks each against the lab,<br/>comments, and sets done or asks you"]
  lh --> status["status.json"]
  status -->|"no good pass for 26 hours"| stale["HealthStale on the phone"]
```

The thresholds, the codes and `expectedOffline` are in
`docs/agents/REFERENCE.md`, under the routines.

## Who watches the watchers

Each piece that would fail quietly has something outside it that notices.
Kuma checks the hosts and expects heartbeats from the jobs. agent-watch
checks the agents host's own services by their status files, and the alert
intake by what's still waiting in Alerta.

```mermaid
flowchart TB
  subgraph kuma["Uptime Kuma on lab118"]
    svc["SVC checks: dashboard, beszel, paperclip,<br/>automation, openclaw, inference"]
    labchecks["LAB checks: tunnel, LAN gateway, DNS,<br/>WAN address, router heartbeat"]
    job["JOB push monitors: backups,<br/>Beszel hub, agent-watch"]
  end

  subgraph aw["agent-watch"]
    es["EventsStale: paperclip-events<br/>disconnected for 5 minutes"]
    bs["BridgeStale: board-bridge<br/>failing for 15 minutes"]
    is["IntakeStale: an alert not handed<br/>over for 15 minutes"]
    hs["HealthStale: no good morning<br/>check for 26 hours"]
  end

  svc -->|"HTTPS over the tunnel"| hosts["Each lab VM's health endpoint"]
  passes["Each good agent-watch pass"] -->|"push"| job
  backups["Each night's backups"] -->|"push"| job
  kuma -->|"down"| alerta["Alerta"]
  aw --> alerta
  alerta --> phone["The phone"]
  gap["Not watched from outside:<br/>the lab118 VPS itself"]
```

agent-watch itself is watched by its own push monitor, so if it stops, Kuma
says so. Nothing outside watches the VPS that holds Kuma, Alerta and ntfy;
that's in the known limits of `docs/lab118-services/REFERENCE.md`.
