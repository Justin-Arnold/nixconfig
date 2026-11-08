# SearXNG, the researcher's web search, on loopback only. It searches engines
# such as DuckDuckGo, Brave and Bing from this VM and answers the
# websearch MCP server (modules/roles/hermes-agents/websearch-mcp/), which
# is the only thing here that asks it: the agents have no terminal on this
# VM. It runs as its own dynamic user, outside the agents' egress filter, so
# it reaches the web like any service.
#
# Its secret_key only signs SearXNG's own cookies, which nobody gets on a
# loopback-only instance, so it's made on this host the first time and kept
# in /var/lib/searx-secret rather than in SOPS.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.searxng;
  secretDir = "/var/lib/searx-secret";
in
{
  options.agents.searxng = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether SearXNG runs on loopback for the researcher's web search.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = "SearXNG's port on 127.0.0.1.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.port}";
      readOnly = true;
      description = "Where the websearch MCP server asks SearXNG.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = config.services.searx.settings.server.bind_address == "127.0.0.1"
        && !config.services.searx.openFirewall && !config.services.searx.configureNginx
        && !(lib.elem cfg.port config.networking.firewall.allowedTCPPorts);
      message = "agents: SearXNG answers on 127.0.0.1 only, with no firewall opening and no nginx in front of it.";
    } ];

    # The secret key, made once with the host's own randomness.
    systemd.services.searx-secret = {
      description = "Make SearXNG's cookie-signing key once";
      wantedBy = [ "searx-init.service" ];
      before = [ "searx-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "searx-secret";
        StateDirectoryMode = "0700";
        UMask = "0077";
      };
      script = ''
        if [ ! -s ${secretDir}/searx.env ]; then
          printf 'SEARX_SECRET_KEY=%s\n' "$(${lib.getExe pkgs.openssl} rand -hex 32)" > ${secretDir}/searx.env.new
          mv ${secretDir}/searx.env.new ${secretDir}/searx.env
        fi
      '';
    };
    systemd.services.searx-init = {
      requires = [ "searx-secret.service" ];
      after = [ "searx-secret.service" ];
    };

    services.searx = {
      enable = true;
      package = pkgs.searxng;
      environmentFile = "${secretDir}/searx.env";
      settings = {
        general.instance_name = "lab";
        server = {
          bind_address = "127.0.0.1";
          inherit (cfg) port;
          secret_key = "$SEARX_SECRET_KEY";
          # Nobody reaches it but this host, so no rate limiter (and no
          # Redis for one), no image proxy and no public-instance checks.
          limiter = false;
          public_instance = false;
          image_proxy = false;
          method = "GET";
        };
        # JSON is what the websearch server asks for.
        search = {
          formats = [ "html" "json" ];
          safe_search = 0;
        };
      };
    };
  };
}
