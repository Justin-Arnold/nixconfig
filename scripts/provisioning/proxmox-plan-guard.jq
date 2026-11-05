# Input: `terraform show -json <planfile>` for a Proxmox host. Prints one line
# per violation; no output means the plan is safe to apply.
#
# provision, install and switch apply without asking, so they must never
# destroy anything: a delete, or a replace (delete then create), of any
# resource is refused. A changed attribute that forces replacement, or a VM
# that Terraform no longer recognises after HA moved it, stops here instead
# of quietly recreating the VM. `nix run .#destroy` is the only way to remove
# a VM, and it doesn't go through this guard.

[ .resource_changes[]?
  | . as $rc
  | ($rc.change.actions // []) as $actions
  | select(($actions | index("delete")) != null)
  | "\($rc.address): \($actions | join("+")) is not allowed outside destroy"
]
| .[]
