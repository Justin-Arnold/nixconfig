# Expansions used on every host that runs the text expander.
{ config, ... }:
{
  roles.textExpansion.groups.base = {
    em = config.systemProfile.email;
    pem = "justin-arnold@programmer.net";
    oem = "justintaylorarnold@gmail.com";
    eface = "👁️🫦👁️";
  };
}
