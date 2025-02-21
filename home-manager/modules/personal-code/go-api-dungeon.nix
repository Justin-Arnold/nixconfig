{ personalPath, pkgs, ... }:

{
  home.packages = [
    # Dependencies
    pkgs.go
  ];
  # This defines the root path of the repository and pulls it down.
  home.activation.cloneGoApiDungeon = {
      after = ["writeBoundary"];
      before = [];
      data = ''
      PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
      if [ ! -d "${personalPath}/go-api-dungeon" ]; then
        git clone git@github.com:Justin-Arnold/go-api-dungeon.git "${personalPath}/go-api-dungeon"
      fi
      '';
  };
}