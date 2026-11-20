# Expansions used on every host that runs the text expander.
{ config, ... }:
{
  roles.textExpansion.groups.base = {
    ";em" = config.systemProfile.email;
    ";eface" = "👁️🫦👁️";
  };
}
