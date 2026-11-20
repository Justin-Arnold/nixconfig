# CGLT expansions, active only where systemProfile.forCglt is set.
# Deleting this file removes them; nothing else references it.
{ config, lib, ... }:
{
  config = lib.mkIf config.systemProfile.forCglt {
    roles.textExpansion.groups.cglt = {
      ";cgem" = "justin@commongoodlt.com";
    };
  };
}
