# Input: `terraform show -json <planfile>`. Prints one line per violation;
# no output means the plan is safe to apply.
#
# Contabo instances must never be created (that is a purchase), deleted
# (cancels the contract) or replaced, and an update may only rename them:
# image_id, ssh_keys, user_data, root_password and default_user changes are
# applied by the provider as a disk-wiping reinstall, and anything else
# unexpected is refused too. Conservative on purpose: an attribute counts as
# changed if its value differs or becomes unknown.

def changed_attributes:
  (.change.before // {}) as $before
  | (.change.after // {}) as $after
  | (.change.after_unknown // {}) as $unknown
  | ([$before, $after, $unknown] | map(keys) | add // [] | unique)
  | map(select(($before[.] != $after[.]) or (($unknown[.] // false) | tostring | test("true"))));

[ .resource_changes[]?
  | . as $rc
  | ($rc.change.actions // []) as $actions
  | if ($actions | index("delete")) != null then
      "\($rc.address): \($actions | join("+")) is not allowed (destroy cancels the contract; replace reinstalls)"
    elif $rc.type == "contabo_instance" and ($actions | index("create")) != null then
      "\($rc.address): create is not allowed (buy in the Contabo panel, then run adopt)"
    elif $rc.type == "contabo_instance" and ($actions | index("update")) != null then
      ($rc | changed_attributes | map(select(. != "display_name"))) as $unsafe
      | if ($unsafe | length) > 0 then
          "\($rc.address): update would change \($unsafe | join(", ")); only display_name may change"
        else empty end
    else empty end
]
| .[]
