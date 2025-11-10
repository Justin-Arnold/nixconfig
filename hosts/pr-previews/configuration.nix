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

    exec ${pkgs.bash}/bin/bash ${./scripts/deploy-preview.sh}
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
  sops.secrets."cglt/font-awesome-token" = {};
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

  systemd.services.webhook = {
    preStart = ''
      mkdir -p /run/webhook

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
    '';

    serviceConfig = {
      ExecStart = pkgs.lib.mkForce "${pkgs.webhook}/bin/webhook -hooks /run/webhook/hooks.json -verbose -ip 127.0.0.1 -port 9000";
    };
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
      webhook-deploy:
        rule: Host(`preview-proxy.commongoodlt.dev`) && Path(`/api/deploy`)
        entryPoints: [ "web" ]
        service: webhook
        middlewares: [ "webhook-deploy-rewrite" ]
        priority: 100

      webhook-cleanup:
        rule: Host(`preview-proxy.commongoodlt.dev`) && Path(`/api/cleanup`)
        entryPoints: [ "web" ]
        service: webhook
        middlewares: [ "webhook-cleanup-rewrite" ]
        priority: 100

      log-stream:
        rule: Host(`preview-proxy.commongoodlt.dev`) && PathPrefix(`/logs`)
        entryPoints: [ "web" ]
        service: log-stream
        priority: 100

      catchall:
        rule: PathPrefix(`/`)
        entryPoints: [ "web" ]
        service: notfound
        priority: -1

    middlewares:
      webhook-deploy-rewrite:
        stripPrefix:
          prefixes: [ "/api" ]
      webhook-cleanup-rewrite:
        stripPrefix:
          prefixes: [ "/api" ]

    services:
      webhook:
        loadBalancer:
          servers:
            - url: "http://127.0.0.1:9000"

      log-stream:
        loadBalancer:
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
  '';

  services.cron = {
    enable = true;
    systemCronJobs = [
      "0 3 * * 0 root ${pkgs.findutils}/bin/find /var/lib/pr-previews/logs -type f -mtime +30 -delete"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/pr-previews 0755 root root -"
    "d /var/lib/pr-previews/logs 0755 root root -"
    "d /etc/traefik/dynamic 0755 root root -"
    "f /var/lib/pr-previews/used-ports.txt 0644 root root -"
  ];

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 512;
  };
}