{ config, pkgs, sops-nix, ... }:

let
  turboCacheDir = "/var/lib/pr-previews/.turbo-cache";
  monorepoGitUrl = "git@github.com:commongoodlt/CGLT-Monorepo.git";
  repoPath = "/var/lib/pr-previews/monorepo";
  stagingIp = "3.13.90.206";


  notFoundPage = pkgs.runCommand "404-page" {} ''
    mkdir -p $out
    cp ${./html/404.html} $out/index.html
  '';

  deployScript = pkgs.writeShellScriptBin "deploy-preview" ''
    set -euo pipefail
    # Read secret at runtime
    export NPM_TOKEN="$(cat ${config.sops.secrets."cglt/font-awesome-token".path})"
    export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -F /etc/webhook/ssh_config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    export RSYNC_RSH="${pkgs.openssh}/bin/ssh -F /etc/webhook/ssh_config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    # Tool paths available as env if you still want to reference them:
    export BASH="${pkgs.bash}/bin/bash"
    export MKDIR="${pkgs.coreutils}/bin/mkdir"
    export RM="${pkgs.coreutils}/bin/rm"
    export CAT="${pkgs.coreutils}/bin/cat"
    export ECHO="${pkgs.coreutils}/bin/echo"
    export TOUCH="${pkgs.coreutils}/bin/touch"
    export MV="${pkgs.coreutils}/bin/mv"
    export TR="${pkgs.coreutils}/bin/tr"
    export DATE="${pkgs.coreutils}/bin/date"
    export GREP="${pkgs.gnugrep}/bin/grep"
    export GIT="${pkgs.git}/bin/git"
    export PNPM="${pkgs.pnpm_9}/bin/pnpm"
    export SEQ="${pkgs.coreutils}/bin/seq"
    export MONOREPO_GIT_URL="${monorepoGitUrl}"

    exec ${pkgs.bash}/bin/bash ${./scripts/deploy-preview.sh} "$@"
  '';

  cleanupScript = pkgs.writeShellScriptBin "cleanup-preview" ''
    set -euo pipefail

    # Tool paths as env vars (match your deploy wrapper’s style)
    export BASH="${pkgs.bash}/bin/bash"
    export RM="${pkgs.coreutils}/bin/rm"
    export GREP="${pkgs.gnugrep}/bin/grep"
    export MV="${pkgs.coreutils}/bin/mv"
    export CAT="${pkgs.coreutils}/bin/cat"
    export MKDIR="${pkgs.coreutils}/bin/mkdir"
    export MKTEMP="${pkgs.coreutils}/bin/mktemp"
    export PNPM="${pkgs.pnpm_9}/bin/pnpm"

    # (No secrets needed for cleanup.)

    exec "${pkgs.bash}/bin/bash" ${./scripts/cleanup-preview.sh} "$@"
  '';


  logStreamServer = pkgs.writeScriptBin "log-stream-server" ''
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.python3}/bin/python3 ${./scripts/log-stream-server.py}
  '';

  deploymentStatusPage = pkgs.runCommand "deployment-status-page" {} ''
    mkdir -p $out
    cp ${./html/deployment-status.html} $out/index.html
  '';

in {
  imports = [ 
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles/server.nix
    ../../modules/platforms/nixos

    sops-nix.nixosModules.sops
  ];

  environment.systemPackages = with pkgs; [
    git
    docker-compose
    curl
    jq
    rsync
    nodejs_22
    pnpm_9
    webhook

    deployScript
    cleanupScript
  ];

  systemProfile = {
    hostname = "pr-previews";
    stateVersion = "25.05";
    isServer = true;
  };

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.secrets."cglt/font-awesome-token" = {
    owner = "webhook";
    group = "webhook";
    mode  = "0400";
  };
  sops.secrets."cglt/preview-api-token" = {
    owner = "webhook";
    group = "webhook";
    mode = "0400";
  };
  
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
  };

  services.webhook = {
    enable = true;
    port = 9000;
    ip = "127.0.0.1";
    verbose = true;

    hooks = {
      dummy = {
        execute-command = "echo";
      };
    };
  };

  environment.etc."webhook/ssh_config".text = ''
  Host github.com
    HostName github.com
    User git
    IdentitiesOnly yes
    IdentityFile /etc/webhook/keys/ssh-service-github
    UserKnownHostsFile /etc/ssh/ssh_known_hosts
    StrictHostKeyChecking accept-new

  Host satchel-staging
    HostName 3.13.90.206
    User ubuntu
    IdentitiesOnly yes
    IdentityFile /etc/webhook/keys/satchel-staging-ssh
    UserKnownHostsFile /etc/ssh/ssh_known_hosts
    StrictHostKeyChecking accept-new
  '';

  systemd.services.webhook = {
    after  = [ "network.target" "sops-nix.service" ];
    wants  = [ "sops-nix.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.rsync pkgs.openssh pkgs.git pkgs.coreutils pkgs.nodejs_22 pkgs.pnpm_9 ];
    # systemd creates /run/webhook (owned by User/Group) *before* ExecStartPre
    serviceConfig = {
      Environment = [
        "PATH=/run/webhook/bin:${pkgs.rsync}/bin:${pkgs.openssh}/bin:${pkgs.nodejs_22}/bin:${pkgs.pnpm_9}/bin:/run/current-system/sw/bin"
      ];

      User = "webhook";
      Group = "webhook";

      # This is the key fix:
      RuntimeDirectory = "webhook";
      RuntimeDirectoryMode = "0750";

      Type = "simple";
      Restart = pkgs.lib.mkForce "always"; 
      RestartSec = "1s";

      ExecStart = pkgs.lib.mkForce ''
        ${pkgs.webhook}/bin/webhook \
          -verbose \
          -hooks /run/webhook/hooks.json \
          -ip 127.0.0.1 \
          -port 9000
      '';
    };
    preStart = ''
      TOKEN=$(cat ${config.sops.secrets."cglt/preview-api-token".path})
      # Generate the webhook config with the token
      cat > /run/webhook/hooks.json << EOF
      [
        {
          "id": "deploy",
          "execute-command": "${deployScript}/bin/deploy-preview",
          "command-working-directory": "/var/lib/pr-previews",
          "response-message": "Deployment started",
          "pass-arguments-to-command": [
            {
              "source": "payload",
              "name": "pr_number"
            },
            {
              "source": "string",
              "name": "Satchel"
            },
            {
              "source": "payload",
              "name": "branch"
            }
          ],
          "trigger-rule": {
            "and": [
              {
                "match": {
                  "type": "value",
                  "value": "Bearer $TOKEN",
                  "parameter": {
                    "source": "header",
                    "name": "Authorization"
                  }
                }
              }
            ]
          },
          "pass-environment-to-command": [
            {
              "source": "string",
              "envname": "HOME",
              "name": "/tmp/webhook-home"
            }
          ]
        },
        {
          "id": "cleanup",
          "execute-command": "${cleanupScript}/bin/cleanup-preview",
          "command-working-directory": "/var/lib/pr-previews",
          "response-message": "Cleanup started",
          "pass-arguments-to-command": [
            {
              "source": "payload",
              "name": "pr_number"
            }
          ],
          "trigger-rule": {
            "and": [
              {
                "match": {
                  "type": "value",
                  "value": "Bearer $TOKEN",
                  "parameter": {
                    "source": "header",
                    "name": "Authorization"
                  }
                }
              }
            ]
          }
        }
      ]
      EOF

      mkdir -p /run/webhook/bin
      cat > /run/webhook/bin/ssh <<'EOS'
      #!/bin/sh
      exec /run/current-system/sw/bin/ssh \
        -F /etc/webhook/ssh_config \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$@"
      EOS

      chmod +x /run/webhook/bin/ssh

      cat > /run/webhook/bin/rsync <<'EOS'
      #!/bin/sh
      # Force rsync to always use our ssh wrapper (covers scripts that call `rsync -e ssh` or just `rsync`)
      exec /run/current-system/sw/bin/rsync -e "/run/webhook/bin/ssh" "$@"
      EOS
      chmod +x /run/webhook/bin/rsync

      # ensure HOME exists for the webhook process (your hook already sets it)
      mkdir -p /tmp/webhook-home
      chown webhook:webhook /tmp/webhook-home
    '';
  };

  systemd.services.log-stream = {
    description = "PR Preview Log Streaming Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${logStreamServer}/bin/log-stream-server";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.services.deployment-status = {
    description = "Deployment Status Page Server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8406 --directory ${deploymentStatusPage}";
    };
  };

  systemd.services.preview-404 = {
    description = "Preview 404 Page";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8404 --directory ${notFoundPage}";
    };
  };

  services.traefik = {
    enable = true;
    
    staticConfigOptions = {
      entryPoints = {
        web = {
          address = ":80";
        };
        websecure = {
          address = ":443";
          http.tls.certResolver = "letsencrypt";
        };
      };
      
      certificatesResolvers.letsencrypt.acme = {
        email = "info@commongoodlt.dev";
        storage = "/var/lib/traefik/acme.json";
        tlsChallenge = true;
      };
      
      api = {
        dashboard = true;
        insecure = true;
      };
      log = {
        level = "DEBUG";
      };

      accessLog = {
        bufferingSize = 0;
        fields = {
          headers.defaultMode = "keep"; # shows all request headers in the log
        };
      };
      # providers.docker = {
      #   exposedByDefault = false;
      #   network = "preview-network";
      # };

      providers.file = {
        directory = "/etc/traefik/dynamic";
        watch = true;
      };
    };
  };

  environment.etc."traefik/dynamic/base.yml".text = ''
  http:
    routers:
      api:
        rule: "PathPrefix(`/api`)"
        entryPoints: [ "web" ]
        service: webhook
        middlewares: [ "api-strip", "api-addprefix" ]
        priority: 200

      log-stream:
        # this one probably *does* depend on host; keep Host() if your proxy preserves it,
        # or relax to PathPrefix if you want it accessible regardless of Host.
        rule: "PathPrefix(`/logs`)"
        entryPoints: [ "web" ]
        service: log-stream
        middlewares: [ "sse-headers" ] 
        priority: 100

      # ... your deployment-status router if you kept it scoped, OR just omit it ...
      catchall:
        rule: "PathPrefix(`/`)"
        entryPoints: [ "web" ]
        service: notfound
        priority: -1

    middlewares:
      api-strip:
        stripPrefix:
          prefixes: [ "/api" ]
      api-addprefix:
        addPrefix:
          prefix: "/hooks"
      sse-headers:
        headers:
          customResponseHeaders:
            Cache-Control: "no-cache"
            Connection: "keep-alive"
            X-Accel-Buffering: "no"
            Content-Type: "text/event-stream"

    services:
      webhook:
        loadBalancer:
          servers:
            - url: "http://127.0.0.1:9000"

      log-stream:
        loadBalancer:
          serversTransport: "sseTransport"
          servers:
            - url: "http://127.0.0.1:8405"

      deployment-status:
        loadBalancer:
          servers:
            - url: "http://127.0.0.1:8406"

      notfound:
        loadBalancer:
          servers:
            - url: "http://127.0.0.1:8404"
    serversTransports:
      sseTransport:
        forwardingTimeouts:
          dialTimeout: "5s"
          responseHeaderTimeout: "0s"
          idleConnTimeout: "0s"
  '';

  services.cron = {
    enable = true;
    systemCronJobs = [
      "0 3 * * 0 root ${pkgs.findutils}/bin/find /var/lib/pr-previews/logs -type f -mtime +30 -delete"
    ];
  };

  systemd.tmpfiles.rules = [
    "z /var/lib/pr-previews 2775 root webhook -"
    "z /var/lib/pr-previews/logs 2775 root webhook -"
    "z /etc/traefik/dynamic 2775 root webhook -"
    "z /var/lib/pr-previews/used-ports.txt 0664 root webhook -"

    "d /etc/webhook/keys 0700 webhook webhook -"
    "C /etc/webhook/keys/ssh-service-github 0400 webhook webhook - /home/justin/.ssh/ssh-service-github"
    "C /etc/webhook/keys/satchel-staging-ssh 0400 webhook webhook - /home/justin/.ssh/satchel-staging-ssh"
  ];

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 512;
  };
}