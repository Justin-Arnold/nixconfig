{ inputs }:
{
  uptime-kuma = import ./hosts/uptime-kuma.nix { inherit inputs; };
}
