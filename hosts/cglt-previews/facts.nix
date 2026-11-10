# Addresses, names and paths the cglt-previews modules share. The paths,
# user, network and middleware names are also a contract with the CGLT
# monorepo's preview workflows and scripts (previews/scripts/*.sh): change
# them there too. docs/cglt-previews/REFERENCE.md lists the contract.
{
  # Preview URLs are <tag>-pr<N>.<domain>; the ops tools are dockhand., files.
  # and mail.<domain>. TLS ends on the Pangolin VPS.
  domain = "preview.commongoodlt.dev";

  # The home site's Newt (the pangolin-newt VM), the only client of port 80
  # (Traefik) and of the deploy port.
  newt = "10.0.0.72";
  # OPNsense: the gateway, DNS (AdGuard) and DHCP.
  gateway = "10.0.0.1";
  # The dashboard VM, where beszel.servicestack.xyz resolves in the LAN. The
  # host's Beszel agent reports there; nothing else on the host needs the LAN.
  beszelHub = "10.0.0.151";
  # Where SSH may come from: the LAN and the road-warrior VPN.
  adminSources = [ "10.0.0.0/24" "10.10.10.0/24" ];
  # Destinations neither the host nor a container may open connections to,
  # except the gateway (and the hub, from the host only). 10.0.0.0/8 covers the
  # LAN, the VPN and the WireGuard tunnel to lab118-services. Uptime Kuma's
  # pushes go to intake.lab118.xyz over the Internet, so they aren't in here.
  blockedV4 = [ "10.0.0.0/8" "100.64.0.0/10" "169.254.0.0/16" "192.168.0.0/16" ];
  blockedV6 = [ "fc00::/7" ];
  # Every Docker network on the host: docker0 (172.17.0.0/16) and the
  # address pool in configuration.nix (172.20.0.0/14).
  containerRange = "172.16.0.0/12";

  # The external Docker network Traefik reaches previews on.
  edgeNetwork = "preview-edge";

  # The deploy user and its sshd port (deploy.nix). GitHub Actions jobs run
  # as it, with the docker group and sudo for zfs and zpool only.
  deployUser = "preview-deploy";
  deployId = 2701;
  deployPort = 2222;

  # tank/previews is mounted here; golden/ and live/ are datasets under it,
  # config/ and stacks/ plain directories owned by the deploy user.
  previewsRoot = "/srv/previews";

  # The ops tools listen on loopback; Traefik publishes them (ingress.nix).
  ports = {
    dockhand = 3000;
    filebrowser = 8081;
    mailpit = 8025;
  };
}
