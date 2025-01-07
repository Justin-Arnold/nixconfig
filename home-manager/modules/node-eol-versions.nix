let
  oldNixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/refs/tags/22.11.tar.gz";
    sha256 = "11w3wn2yjhaa5pv20gbfbirvjq6i3m7pqrq2msf0g7cv44vijwgw";
  };
  oldPkgs = import oldNixpkgs { system = "aarch64-darwin"; };
in {
 nodejs-16 = oldPkgs.nodejs-16_x;
}