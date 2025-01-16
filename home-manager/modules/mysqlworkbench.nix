{ pkgs, ... }:
# We use Doppler for secret management for Spectora
{
    home.packages = [
        pkgs.mysql-workbench
    ];
}
