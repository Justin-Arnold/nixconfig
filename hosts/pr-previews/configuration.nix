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

    # Scripts can access config.sops.secrets here!
  deployScript = pkgs.substituteAll {
    src = ./scripts/deploy-preview.sh;
    name = "deploy-preview";
    dir = "bin";
    isExecutable = true;
    
    inherit monorepoGitUrl;
    npmToken = builtins.readFile config.sops.secrets."cglt/font-awesome-token".path;

    bash  = "${pkgs.bash}/bin/bash";
    mkdir = "${pkgs.coreutils}/bin/mkdir";
    rm    = "${pkgs.coreutils}/bin/rm";
    cat   = "${pkgs.coreutils}/bin/cat";
    echo  = "${pkgs.coreutils}/bin/echo";
    touch = "${pkgs.coreutils}/bin/touch";
    mv    = "${pkgs.coreutils}/bin/mv";
    tr    = "${pkgs.coreutils}/bin/tr";
    date  = "${pkgs.coreutils}/bin/date";
    grep  = "${pkgs.gnugrep}/bin/grep";
    git   = "${pkgs.git}/bin/git";
    pnpm  = "${pkgs.pnpm_9}/bin/pnpm";
    seq   = "${pkgs.coreutils}/bin/seq";
  };

  cleanupScript = pkgs.substituteAll {
    src = ./scripts/cleanup-preview.sh;
    name = "cleanup-preview";
    dir = "bin";
    isExecutable = true;
    
    bash = "${pkgs.bash}/bin/bash";
    cat  = "${pkgs.coreutils}/bin/cat";
    rm   = "${pkgs.coreutils}/bin/rm";
    mv   = "${pkgs.coreutils}/bin/mv";
    grep = "${pkgs.gnugrep}/bin/grep";
    pnpm = "${pkgs.pnpm_9}/bin/pnpm";
  };

  logStreamServer = pkgs.writeScriptBin "log-stream-server" ''
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.python3}/bin/python3 ${./scripts/log-stream-server.py}
  '';

  deploymentStatusPage = ./html;

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
    hooks = "/run/webhook/hooks.json";
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
      
      providers.docker = {
        exposedByDefault = false;
        network = "preview-network";
      };

      providers.file = {
        directory = "/etc/traefik/dynamic";
        watch = true;
      };
    };

    dynamicConfigOptions = {
      http = {
        routers = {
          webhook-deploy = {
            rule = "Host(`preview-proxy.commongoodlt.dev`) && Path(`/api/deploy`)";
            service = "webhook";
            entryPoints = [ "websecure" ];
            tls.certResolver = "letsencrypt";
            middlewares = [ "webhook-deploy-rewrite" ];
          };
          webhook-cleanup = {
            rule = "Host(`preview-proxy.commongoodlt.dev`) && Path(`/api/cleanup`)";
            service = "webhook";
            entryPoints = [ "websecure" ];
            tls.certResolver = "letsencrypt";
            middlewares = [ "webhook-cleanup-rewrite" ];
          };
          log-stream = {
            rule = "Host(`preview-proxy.commongoodlt.dev`) && PathPrefix(`/logs`)";
            service = "log-stream";
            entryPoints = [ "websecure" ];
            tls.certResolver = "letsencrypt";
          };
          deployment-status = {
            rule = "HostRegexp(`^pr-[0-9]+-[a-z]+\\.preview\\.commongoodlt\\.dev$`)";
            service = "deployment-status";
            priority = 5;
            entryPoints = [ "websecure" ];
            tls.certResolver = "letsencrypt";
          };
          catchall = {
            rule = "PathPrefix(`/`)";
            service = "notfound";
            priority = 1;
            entryPoints = [ "web" ];
          };
        };
        middlewares = {
          webhook-deploy-rewrite = {
            stripPrefix = {
              prefixes = [ "/api" ];
            };
          };
          webhook-cleanup-rewrite = {
            stripPrefix = {
              prefixes = [ "/api" ];
            };
          };
        };
        services = {
          webhook = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:9000"; }
              ];
            };
          };
          log-stream = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:8405"; }
              ];
            };
          };
          deployment-status = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:8406"; }
              ];
            };
          };
          notfound = {
            loadBalancer = {
              servers = [
                { url = "http://localhost:8404"; }
              ];
            };
          };
        };
      };
    };
  };

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