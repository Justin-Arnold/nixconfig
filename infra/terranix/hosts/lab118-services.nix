{ inputs }:
let
  mkContaboInstance = import ../lib/contabo-instance.nix {
    lib = inputs.nixpkgs.lib;
  };
in
mkContaboInstance {
  name = "lab118-services";
  # Cloud VPS 12, 400 GB SSD, monthly term.
  productId = "V156";
  region = "EU";
  period = 1;
}
