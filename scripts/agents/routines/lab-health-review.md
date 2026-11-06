The morning check of Justin's lab, for {{date}}.

Read each source once with your lab tools:
- `proxmox_cluster` for the nodes, HA and quorum, `proxmox_resources` for
  guests and storage, and `proxmox_failed_tasks` for tasks that failed in the
  last 24 hours;
- `beszel_systems` for every system's status, CPU, memory and disk;
- `kuma_monitors` for monitors that are down;
- `alerta_alerts` for the open alerts.

Then write one comment:
1. The first line is "Needs you: ..." with what and why, or "Nothing needs
   you today."
2. What's down or degraded now, one line each: nodes or guests that should
   be running and aren't, HA resources in error, systems that are down,
   monitors that are down.
3. What's heading the wrong way: disks or storage at 85% or more, memory
   that's nearly full, Proxmox tasks that failed, alerts open for more than a
   day.
4. Anything you couldn't read, and why.

Leave out what's fine. Then, if something needs Justin, ask him to do it
and confirm as in "Asking Justin", and leave this issue blocked; otherwise
set it to done.
