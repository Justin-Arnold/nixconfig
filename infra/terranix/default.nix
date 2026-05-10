{ inputs }:
{
  pr-previews = import ./hosts/pr-previews.nix { inherit inputs; };
  uptime-kuma = import ./hosts/uptime-kuma.nix { inherit inputs; };
}
