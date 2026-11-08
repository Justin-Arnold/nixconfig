# n8n (services.n8n): the router between systems. GitHub's webhook
# deliveries reach it through intake.lab118.xyz and the tunnel, and it answers
# them by firing Paperclip routines through their webhook triggers or raising
# alerts in Alerta. Its workflows and credentials come from the repo through
# scripts/automation/n8n-apply.py, so the UI is for looking, not editing.
#
# It listens on 127.0.0.1 and nginx publishes it (endpoints.nix). Its data is
# SQLite in /var/lib/n8n/.n8n, backed up nightly (backup.nix). It may reach
# the internet, Paperclip's trigger server block on the agents VM and Alerta
# over the tunnel, and nothing else in the lab.
{ config, lib, ... }:
let
  cfg = config.services.n8n;
  service = config.systemd.services.n8n.serviceConfig;

  privateRanges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16" "fc00::/7" "fe80::/10" ];
  # The agents VM, where nginx lets this host's address reach Paperclip's
  # routine triggers and nothing else.
  agentsVm = "10.0.0.152";
  # lab118-services's end of the tunnel, where Alerta's API listens.
  lab118 = "10.118.0.1";

  # Nodes n8n won't load, even for an edit in the UI: anything that runs code
  # (JavaScript or Python, the AI Transform node's included), reaches the
  # host's files, git, SSH or FTP, or drives n8n's own API. The first two are
  # n8n's default. scripts/automation/n8n-apply.py refuses them in the repo's
  # workflow files as well, from a shorter list of what's allowed.
  excludedNodes = map (n: "n8n-nodes-base.${n}") [
    "executeCommand"
    "localFileTrigger"
    "code"
    "function"
    "functionItem"
    "aiTransform"
    "ssh"
    "ftp"
    "git"
    "readWriteFile"
    "readBinaryFile"
    "readBinaryFiles"
    "writeBinaryFile"
    "readPdf"
    "n8n"
  ] ++ [ "@n8n/n8n-nodes-langchain.code" "@n8n/n8n-nodes-langchain.toolCode" ];
in
{
  sops.secrets."n8n/encryption-key".restartUnits = [ "n8n.service" ];

  # A fixed UID instead of a dynamic one, so the data stays outside
  # /var/lib/private and restored files and backups keep a predictable owner.
  users.groups.n8n.gid = 5678;
  users.users.n8n = {
    isSystemUser = true;
    uid = 5678;
    group = "n8n";
    home = "/var/lib/n8n";
    description = "n8n";
  };

  services.n8n = {
    enable = true;
    environment = {
      N8N_LISTEN_ADDRESS = "127.0.0.1";
      N8N_HOST = "automation.servicestack.xyz";
      N8N_PROTOCOL = "https";
      N8N_EDITOR_BASE_URL = "https://automation.servicestack.xyz/";
      N8N_WEBHOOK_URL = "https://automation.servicestack.xyz/";
      # nginx on this host is the one proxy in front.
      N8N_PROXY_HOPS = 1;
      # Encrypts the credentials n8n stores. Losing it loses them all, so it
      # comes from SOPS rather than being generated on first start.
      N8N_ENCRYPTION_KEY_FILE = config.sops.secrets."n8n/encryption-key".path;

      # Nothing calls home or pulls code in.
      N8N_DIAGNOSTICS_ENABLED = false;
      N8N_VERSION_NOTIFICATIONS_ENABLED = false;
      N8N_TEMPLATES_ENABLED = false;
      N8N_COMMUNITY_PACKAGES_ENABLED = false;
      # Workflows come from the repo, so nothing drives n8n as an MCP server.
      N8N_MCP_MANAGED_BY_ENV = true;
      N8N_MCP_ACCESS_ENABLED = false;
      N8N_PUBLIC_API_SWAGGERUI_DISABLED = true;
      # Nodes can't read the service's environment or run commands.
      N8N_BLOCK_ENV_ACCESS_IN_NODE = true;
      NODES_EXCLUDE = builtins.toJSON excludedNodes;
    };
  };

  systemd.services.n8n.serviceConfig = {
    # The nixpkgs unit uses DynamicUser, which keeps the data under
    # /var/lib/private (root only). The backup snapshots as the file's owner
    # and couldn't reach it from there.
    DynamicUser = lib.mkForce false;
    User = "n8n";
    Group = "n8n";
    # The database holds the API keys and every stored delivery, so other
    # services on the host can't look inside, like Homarr's and Paperclip's.
    StateDirectoryMode = "0750";
    IPAddressAllow = [ "localhost" agentsVm lab118 ];
    IPAddressDeny = privateRanges;
  };

  assertions = [
    {
      assertion = cfg.environment.N8N_LISTEN_ADDRESS == "127.0.0.1" && !cfg.openFirewall;
      message = "automation: n8n listens on 127.0.0.1 only; nginx publishes it.";
    }
    {
      # The webhook secret, Paperclip's trigger secrets and Alerta's key are
      # n8n credentials, so they can't reach the rest of the lab.
      assertion = lib.sort lib.lessThan service.IPAddressAllow == lib.sort lib.lessThan [ "localhost" agentsVm lab118 ]
        && lib.all (range: lib.elem range service.IPAddressDeny) privateRanges;
      message = "automation: n8n reaches only loopback, the internet, ${agentsVm} (Paperclip's triggers) and ${lab118} (Alerta).";
    }
    {
      assertion = lib.all (node: lib.elem node (builtins.fromJSON cfg.environment.NODES_EXCLUDE)) excludedNodes
        && cfg.environment.N8N_BLOCK_ENV_ACCESS_IN_NODE == "true"
        && cfg.environment.N8N_COMMUNITY_PACKAGES_ENABLED == "false";
      message = "automation: n8n keeps every node in excludedNodes (code, files, SSH, FTP, git, its own API) excluded, environment access blocked and community packages off.";
    }
    {
      assertion = !(cfg.environment ? N8N_ENCRYPTION_KEY);
      message = "automation: n8n's encryption key comes from a file (N8N_ENCRYPTION_KEY_FILE), never the environment.";
    }
  ];
}
