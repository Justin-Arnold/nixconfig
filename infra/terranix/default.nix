{ inputs }:
{
  dockhand = import ./hosts/dockhand.nix { inherit inputs; };
  pr-previews = import ./hosts/pr-previews.nix { inherit inputs; };
  uptime-kuma = import ./hosts/uptime-kuma.nix { inherit inputs; };
}
