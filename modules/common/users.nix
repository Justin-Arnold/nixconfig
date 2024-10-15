{ config, pkgs, ... }:

{
  users.users.justin = {
    isNormalUser = true;
    description = "Justin Arnold";
    extraGroups = [ "networkmanager" "wheel" ];
  };
}
