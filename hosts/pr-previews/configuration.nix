{ config, pkgs, ... }:

let
  turboCacheDir = "/var/lib/pr-previews/.turbo-cache";
  monorepoGitUrl = "git@github.com:commongoodlt/CGLT-Monorepo.git";
  
  syncDataScript = pkgs.writeScriptBin "sync-preview-data" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    
    CACHE_DIR="/var/lib/pr-previews/.cache"
    REPO_PATH=$1
    DB_DUMP_URL="''${2:-https://your-storage.com/dumps/latest.sql.gz}"
    FILESTORE_URL="''${3:-https://your-storage.com/filestore.tar.gz}"
    
    ${pkgs.coreutils}/bin/mkdir -p "$CACHE_DIR"
    
    # Get version from repo
    if [ ! -f "$REPO_PATH/db-version.txt" ]; then
      echo "Warning: No db-version.txt found in repo, skipping version check"
      REPO_VERSION="unknown"
    else
      REPO_VERSION=$(${pkgs.coreutils}/bin/cat "$REPO_PATH/db-version.txt")
    fi
    
    CACHED_VERSION=""
    if [ -f "$CACHE_DIR/db-version.txt" ]; then
      CACHED_VERSION=$(${pkgs.coreutils}/bin/cat "$CACHE_DIR/db-version.txt")
    fi
    
    # Only download if versions don't match
    if [ "$REPO_VERSION" != "$CACHED_VERSION" ]; then
      echo "Database version changed: $CACHED_VERSION → $REPO_VERSION"
      echo "Downloading fresh data..."
      
      # Download DB dump
      echo "Downloading database dump..."
      ${pkgs.curl}/bin/curl -L "$DB_DUMP_URL" -o "$CACHE_DIR/latest.sql.gz"
      
      # Download and extract filestore
      echo "Downloading filestore..."
      ${pkgs.curl}/bin/curl -L "$FILESTORE_URL" -o "$CACHE_DIR/filestore.tar.gz"
      ${pkgs.coreutils}/bin/rm -rf "$CACHE_DIR/filestore"
      ${pkgs.gnutar}/bin/tar -xzf "$CACHE_DIR/filestore.tar.gz" -C "$CACHE_DIR"
      
      # Save version
      echo "$REPO_VERSION" > "$CACHE_DIR/db-version.txt"
      
      echo "Data updated to version: $REPO_VERSION"
    else
      echo "Using cached data (version: $CACHED_VERSION)"
    fi
    
    # Output paths for docker-compose
    echo "DB_DUMP=$CACHE_DIR/latest.sql.gz"
    echo "FILESTORE=$CACHE_DIR/filestore"
  '';
  
  deployScript = pkgs.writeScriptBin "deploy-preview" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    
    PR_NUMBER=$1
    WORKSPACE=$2
    BRANCH=$3
    REPO_URL="''${4:-$monorepoGitUrl}"
    
    PREVIEW_DIR="/var/lib/pr-previews/pr-''${PR_NUMBER}-''${WORKSPACE}"
    SCRIPTS_DIR="/var/lib/pr-previews/scripts"
    
    echo "=== Deploying PR #''${PR_NUMBER} - ''${WORKSPACE} ==="
    
    # Create preview directory
    ${pkgs.coreutils}/bin/mkdir -p "$PREVIEW_DIR"
    cd "$PREVIEW_DIR"
    
    # Clone or update repo
    if [ ! -d "repo" ]; then
      echo "Cloning repository..."
      ${pkgs.git}/bin/git clone --depth 1 --branch "$BRANCH" "$REPO_URL" repo
    else
      echo "Updating repository..."
      cd repo
      ${pkgs.git}/bin/git fetch origin "$BRANCH"
      ${pkgs.git}/bin/git reset --hard "origin/$BRANCH"
      cd ..
    fi
    
    # Sync data (DB dump and filestore)
    echo "Checking data cache..."
    eval $(${syncDataScript}/bin/sync-preview-data "$PREVIEW_DIR/repo")
    echo "Data ready: DB=$DB_DUMP, Filestore=$FILESTORE"
    
    # Create data directory and link filestore
    ${pkgs.coreutils}/bin/mkdir -p "$PREVIEW_DIR/data"
    ${pkgs.coreutils}/bin/ln -sf "$FILESTORE" "$PREVIEW_DIR/data/filestore"
    
    # Build with turbo (shared cache)
    echo "Building dependencies..."
    cd repo
    export HOME=/tmp/pnpm-home
    ${pkgs.coreutils}/bin/mkdir -p $HOME
    ${pkgs.nodejs_20}/bin/npx pnpm install --frozen-lockfile
    
    # Link shared turbo cache
    ${pkgs.coreutils}/bin/ln -sf "${turboCacheDir}" .turbo
    ${pkgs.nodejs_20}/bin/npx turbo build --filter=@yourcompany/components --filter=@yourcompany/shared
    cd ..
    
    # Generate docker-compose.yml
    ${pkgs.coreutils}/bin/cat > docker-compose.yml <<EOF
    version: '3.8'

    services:
      frontend-''${PR_NUMBER}-''${WORKSPACE}:
        build:
          context: ./repo
          dockerfile: Dockerfile.dev
        environment:
          - VITE_API_URL=https://pr-''${PR_NUMBER}-''${WORKSPACE}-api.preview.commongoodlt.dev
          - WORKSPACE=''${WORKSPACE}
        command: pnpm --filter ''${WORKSPACE} dev --host
        volumes:
          - ./repo:/app
          - ./data/filestore:/app/filestore:ro
          - /app/node_modules
          - ${turboCacheDir}:/app/.turbo
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.pr-''${PR_NUMBER}-''${WORKSPACE}-frontend.rule=Host(\`pr-''${PR_NUMBER}-''${WORKSPACE}.preview.commongoodlt.dev\`)"
          - "traefik.http.routers.pr-''${PR_NUMBER}-''${WORKSPACE}-frontend.entrypoints=websecure"
          - "traefik.http.routers.pr-''${PR_NUMBER}-''${WORKSPACE}-frontend.tls.certresolver=letsencrypt"
          - "traefik.http.services.pr-''${PR_NUMBER}-''${WORKSPACE}-frontend.loadbalancer.server.port=5173"
        networks:
          - preview-network
        depends_on:
          db-''${PR_NUMBER}-''${WORKSPACE}:
            condition: service_healthy

      php-''${PR_NUMBER}-''${WORKSPACE}:
        image: php:8.2-fpm
        volumes:
          - ./repo/apps/''${WORKSPACE}/backend:/var/www/html
          - ./data/filestore:/var/www/html/filestore:ro
        environment:
          - DB_HOST=db-''${PR_NUMBER}-''${WORKSPACE}
          - DB_NAME=preview_''${PR_NUMBER}
          - DB_USER=preview
          - DB_PASSWORD=preview123
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.pr-''${PR_NUMBER}-''${WORKSPACE}-api.rule=Host(\`pr-''${PR_NUMBER}-''${WORKSPACE}-api.preview.commongoodlt.dev\`)"
          - "traefik.http.routers.pr-''${PR_NUMBER}-''${WORKSPACE}-api.entrypoints=websecure"
          - "traefik.http.routers.pr-''${PR_NUMBER}-''${WORKSPACE}-api.tls.certresolver=letsencrypt"
        networks:
          - preview-network

      db-''${PR_NUMBER}-''${WORKSPACE}:
        image: mysql:8.0
        environment:
          - MYSQL_DATABASE=preview_''${PR_NUMBER}
          - MYSQL_USER=preview
          - MYSQL_PASSWORD=preview123
          - MYSQL_ROOT_PASSWORD=rootpass123
        volumes:
          - ''${DB_DUMP}:/docker-entrypoint-initdb.d/dump.sql.gz:ro
          - db-data-''${PR_NUMBER}-''${WORKSPACE}:/var/lib/mysql
        healthcheck:
          test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
          interval: 5s
          timeout: 5s
          retries: 20
        networks:
          - preview-network

    volumes:
      db-data-''${PR_NUMBER}-''${WORKSPACE}:

    networks:
      preview-network:
        external: true
    EOF
    
    # Start services
    echo "Starting containers..."
    ${pkgs.docker-compose}/bin/docker-compose up -d
    
    # Wait for database to initialize (first time only)
    if [ ! -f ".db-initialized" ]; then
      echo "Waiting for database initialization..."
      until ${pkgs.docker-compose}/bin/docker-compose exec -T db-''${PR_NUMBER}-''${WORKSPACE} mysqladmin ping -h localhost --silent 2>/dev/null; do
        ${pkgs.coreutils}/bin/sleep 2
      done
      ${pkgs.coreutils}/bin/sleep 10
      ${pkgs.coreutils}/bin/touch .db-initialized
    fi
    
    echo "=== Deployment complete ==="
    echo "Frontend: https://pr-''${PR_NUMBER}-''${WORKSPACE}.preview.commongoodlt.dev"
    echo "API: https://pr-''${PR_NUMBER}-''${WORKSPACE}-api.preview.commongoodlt.dev"
  '';

  cleanupScript = pkgs.writeScriptBin "cleanup-preview" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    
    PR_NUMBER=$1
    
    echo "Cleaning up all previews for PR #''${PR_NUMBER}"
    
    for dir in /var/lib/pr-previews/pr-''${PR_NUMBER}-*/; do
      if [ -d "$dir" ]; then
        echo "Removing: $dir"
        cd "$dir"
        ${pkgs.docker-compose}/bin/docker-compose down -v 2>/dev/null || true
        cd /var/lib/pr-previews
        ${pkgs.coreutils}/bin/rm -rf "$dir"
      fi
    done
    
    echo "Cleanup complete for PR #''${PR_NUMBER}"
  '';
  
  cleanupOldPreviewsScript = pkgs.writeScriptBin "cleanup-old-previews" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    
    MAX_AGE_DAYS=7
    PREVIEW_DIR="/var/lib/pr-previews"
    
    echo "Cleaning up preview environments older than $MAX_AGE_DAYS days..."
    
    ${pkgs.findutils}/bin/find "$PREVIEW_DIR" -maxdepth 1 -type d -name "pr-*-*" -mtime +$MAX_AGE_DAYS | while read dir; do
      if [ -d "$dir" ]; then
        echo "Removing old preview: $dir"
        cd "$dir"
        ${pkgs.docker-compose}/bin/docker-compose down -v 2>/dev/null || true
        cd "$PREVIEW_DIR"
        ${pkgs.coreutils}/bin/rm -rf "$dir"
      fi
    done
    
    echo "Old preview cleanup complete"
  '';
  
  clearCacheScript = pkgs.writeScriptBin "clear-preview-cache" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    
    CACHE_DIR="/var/lib/pr-previews/.cache"
    
    echo "Clearing preview data cache..."
    ${pkgs.coreutils}/bin/rm -rf "$CACHE_DIR"/*
    ${pkgs.coreutils}/bin/mkdir -p "$CACHE_DIR"
    
    echo "✅ Cache cleared. Next PR deployment will download fresh data."
  '';

in {
  imports = [ 
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles/server.nix
    ../../modules/platforms/nixos
  ];

  environment.systemPackages = with pkgs; [
    git
    docker-compose
    curl
    jq
    rsync
    nodejs_20

    deployScript
    cleanupScript
    syncDataScript
    cleanupOldPreviewsScript
    clearCacheScript
  ];

  systemProfile = {
    hostname = "pr-previews";
    stateVersion = "25.05";
    isServer = true;
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 8404 ];
  };

  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--all" "--volumes" ];
    };
  };

  systemd.services.preview-404 = {
    description = "Preview 404 Page";
    after = [ "network.target" "docker-network-preview.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8404 --directory /var/lib/pr-previews/404";
      WorkingDirectory = "/var/lib/pr-previews/404";
    };
  };

  services.traefik = {
    enable = true;
    
    staticConfigOptions = {
      entryPoints = {
        web = {
          address = ":80";
          # http.redirections.entrypoint = {
          #   to = "websecure";
          #   scheme = "https";
          # };
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
        filename = "/etc/traefik/dynamic.yml";
        watch = true;
      };
    };

     dynamicConfigOptions = {
      http = {
        routers = {
          catchall = {
            rule = "PathPrefix(`/`)";
            service = "notfound";
            priority = 1;
            entryPoints = [ "web" ];
          };
        };
        services = {
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

  systemd.services.docker-network-preview = {
    description = "Create Docker preview network";
    after = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.docker}/bin/docker network create preview-network || true'";
    };
  };

  systemd.services.traefik.after = [ "docker-network-preview.service" ];
  systemd.services.traefik.requires = [ "docker-network-preview.service" ];

  services.cron = {
    enable = true;
    systemCronJobs = [
      # Cleanup old previews daily at 2am
      "0 2 * * * root ${cleanupOldPreviewsScript}/bin/cleanup-old-previews"
      # Docker system prune weekly on Sunday at 3am
      "0 3 * * 0 root ${pkgs.docker}/bin/docker system prune -af --volumes"
      # Clean turbo cache weekly (keep under 10GB)
      "0 4 * * 0 root ${pkgs.findutils}/bin/find ${turboCacheDir} -type f -atime +7 -delete"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/pr-previews 0755 root root -"
    "d /var/lib/pr-previews/.cache 0755 root root -"
    "d /var/lib/pr-previews/404 0755 root root -"
    "d ${turboCacheDir} 0755 root root -"
  ];

  environment.etc."pr-previews-404/index.html" = {
    text = ''
      <!DOCTYPE html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Preview Not Found</title>
          <style>
              * {
                  margin: 0;
                  padding: 0;
                  box-sizing: border-box;
              }
              
              body {
                  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                  min-height: 100vh;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  padding: 20px;
              }
              
              .container {
                  background: white;
                  border-radius: 20px;
                  padding: 60px 40px;
                  max-width: 600px;
                  text-align: center;
                  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
                  animation: fadeIn 0.5s ease-in;
              }
              
              @keyframes fadeIn {
                  from {
                      opacity: 0;
                      transform: translateY(-20px);
                  }
                  to {
                      opacity: 1;
                      transform: translateY(0);
                  }
              }
              
              .error-code {
                  font-size: 120px;
                  font-weight: 700;
                  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                  -webkit-background-clip: text;
                  -webkit-text-fill-color: transparent;
                  background-clip: text;
                  margin-bottom: 20px;
                  line-height: 1;
              }
              
              h1 {
                  font-size: 32px;
                  color: #2d3748;
                  margin-bottom: 15px;
              }
              
              p {
                  font-size: 18px;
                  color: #718096;
                  line-height: 1.6;
                  margin-bottom: 30px;
              }
              
              .info-box {
                  background: #f7fafc;
                  border-left: 4px solid #667eea;
                  padding: 20px;
                  border-radius: 8px;
                  text-align: left;
                  margin-top: 30px;
              }
              
              .info-box h3 {
                  color: #2d3748;
                  margin-bottom: 10px;
                  font-size: 16px;
              }
              
              .info-box ul {
                  list-style: none;
                  color: #4a5568;
                  font-size: 14px;
                  line-height: 1.8;
              }
              
              .info-box li:before {
                  content: "→ ";
                  color: #667eea;
                  font-weight: bold;
                  margin-right: 8px;
              }
              
              .hostname {
                  font-family: 'Courier New', monospace;
                  background: #edf2f7;
                  padding: 2px 8px;
                  border-radius: 4px;
                  color: #667eea;
                  font-weight: 600;
              }
          </style>
      </head>
      <body>
          <div class="container">
              <div class="error-code">404</div>
              <h1>Preview Environment Not Found</h1>
              <p>The preview environment you're looking for doesn't exist or has been closed.</p>
              <p>You tried to access: <span class="hostname" id="hostname"></span></p>
              
              <div class="info-box">
                  <h3>Common reasons:</h3>
                  <ul>
                      <li>The Pull Request has been merged or closed</li>
                      <li>The preview environment was cleaned up (older than 7 days)</li>
                      <li>The URL may contain a typo</li>
                      <li>The deployment is still in progress</li>
                  </ul>
              </div>
          </div>
          
          <script>
              document.getElementById('hostname').textContent = window.location.hostname;
          </script>
      </body>
      </html>
    '';
    mode = "0644";
  };

  system.activationScripts.setup404Page = ''
    mkdir -p /var/lib/pr-previews/404
    ln -sf /etc/pr-previews-404/index.html /var/lib/pr-previews/404/index.html
  '';

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 512;
  };
}