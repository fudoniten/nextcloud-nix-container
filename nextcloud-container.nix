{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.services.nextcloudContainer;

  hostname = config.instance.hostname;

  hostSecrets = config.fudo.secrets.host-secrets."${hostname}";

  mkEnvFile = envVars:
    let
      envLines =
        mapAttrsToList (var: val: ''${var}="${toString val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  mkUserMap = uid: "${toString uid}:${toString uid}";

  postgresPasswdFile =
    pkgs.lib.passwd.stablerandom-passwd-file "nextcloud-postgres-passwd"
    config.instance.build-seed;

in {
  options.services.nextcloudContainer = with types; {
    enable = mkEnableOption "Enable Nextcloud running in an Arion container.";

    state-directory = mkOption {
      type = str;
      description = "Directory at which to store server state data.";
    };

    images = {
      nextcloud = mkOption { type = str; };
      postgres = mkOption { type = str; };
    };

    uids = {
      nextcloud = mkOption {
        type = int;
        default = 740;
      };
      postgres = mkOption {
        type = int;
        default = 741;
      };
    };

    port = mkOption {
      type = port;
      description = "Intenal port on which to listen for requests.";
      default = 6093;
    };

    timezone = mkOption {
      type = str;
      default = "America/Winnipeg";
    };
  };

  config = mkIf cfg.enable {
    systemd = {
      tmpfiles.rules = [
        "d ${cfg.state-directory}/nextcloud  0700 nextcloud          root - -"
        "d ${cfg.state-directory}/data       0700 nextcloud          root - -"
        "d ${cfg.state-directory}/postgres   0700 nextcloud-postgres root - -"
      ];
      services.arion-nextcloud = {
        after = [ "network-online.target" ];
        requires = [ "network-online.target" ];
      };
    };

    users.users = {
      nextcloud = {
        isSystemUser = true;
        group = "nextcloud";
        uid = cfg.uids.nextcloud;
      };
      nextcloud-postgres = {
        isSystemUser = true;
        group = "nextcloud";
        uid = cfg.uids.postgres;
      };
    };

    fudo.secrets.host-secrets."${hostname}" = {
      nextcloudEnv = {
        source-file = mkEnvFile {
          POSTGRES_HOST = "postgres";
          POSTGRES_DB = "nextcloud";
          POSTGRES_USER = "nextcloud";
          POSTGRES_PASSWORD = readFile postgresPasswdFile;
          TZ = cfg.timezone;
        };
        target-file = "/run/nextcloud/nextcloud.env";
      };
      nextcloudPostgresEnv = {
        source-file = mkEnvFile {
          POSTGRES_DB = "nextcloud";
          POSTGRES_USER = "nextcloud";
          POSTGRES_PASSWORD = readFile postgresPasswdFile;
        };
        target-file = "/run/nextcloud/postgres.env";
      };
    };

    virtualisation.arion.projects.nextcloud.settings = let
      image = { ... }: {
        project.name = "nextcloud";
        services = {
          nextcloud.service = {
            image = cfg.images.nextcloud;
            restart = "always";
            env_file = [ hostSecrets.nextcloudEnv.target-file ];
            volumes = [
              "${cfg.state-directory}/nextcloud:/var/www/html"
              "${cfg.state-directory}/data:/data"
            ];
            user = mkUserMap cfg.uids.nextcloud;
            depends_on = [ "postgres" ];
          };
          postgres.service = {
            image = cfg.images.postgres;
            restart = "always";
            command = "-c 'max_connections=300'";
            env_file = [ hostSecrets.nextcloudPostgresEnv.target-file ];
            volumes =
              [ "${cfg.state-directory}/postgres:/var/lib/postgresql/data" ];
            healthcheck = {
              test = [ "CMD" "pg_isready" "-U" "authentik" "-d" "authentik" ];
              start_period = "20s";
              interval = "30s";
              timeout = "3s";
              retries = 5;
            };
            user = mkUserMap cfg.uids.postgres;
          };
          proxy = { lib, ... }: {
            nixos = {
              useSystemd = true;
              configuration = {
                boot.tmpOnTmpfs = true;
                system.nssModules = lib.mkForce [ ];
                systemd.services.nginx.serviceConfig.AmbientCapabilities =
                  lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
                services = {
                  nscd.enable = false;
                  nginx = {
                    enable = true;
                    recommendedOptimisation = true;
                    recommendedGzipSettings = true;
                    recommendedProxySettings = true;
                    upstreams.php-handler.extraConfig =
                      "server nextcloud:9000;";
                    virtualHosts."localhost" = {
                      extraConfig = ''
                        add_header Referrer-Policy "no-referrer" always;
                        add_header X-Content-Type-Options "nosniff" always;
                        add_header X-Download-Options "noopen" always;
                        add_header X-Frame-Options "SAMEORIGIN" always;
                        add_header X-Permitted-Cross-Domain-Policies "none" always;
                        add_header X-Robots-Tag "none" always;
                        add_header X-XSS-Protection "1; mode=block" always;
                        fastcgi_hide_header X-Powered-By;
                        client_max_body_size 10G;
                        fastcgi_buffers 64 4K;
                      '';
                      locations = {
                        "/robots.txt".extraConfig = ''
                          allow all;
                          log_not_found off;
                          access_log off;
                        '';
                        "/.well-known/carddav" = {
                          return =
                            "301 $scheme://$host:$server_port/remote.hph/dav";
                        };
                        "/.well-known/caldav" = {
                          return =
                            "301 $scheme://$host:$server_port/remote.hph/dav";
                        };
                        "/" = { extraConfig = "rewrite ^ /index.php"; };
                        "~ ^/(?:build|tests|config|lib|3rdparty|templates|data)/".extraConfig =
                          "deny all;";
                        "~ ^/(?:.|autotest|occ|issue|indie|db_|console)".extraConfig =
                          "deny all;";
                        "~ ^/(?:index|remote|public|cron|core/ajax/update|status|ocs/v[12]|updater/.+|oc[ms]-provider/.+).php(?:$|/)".extraConfig =
                          ''
                            fastcgi_split_path_info ^(.+?\.php)(\/.*|)$;
                            set $path_info $fastcgi_path_info;
                            try_files $fastcgi_script_name =404;
                            include fastcgi_params;
                            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                            fastcgi_param PATH_INFO $path_info;
                            # fastcgi_param HTTPS on;

                            # Avoid sending the security headers twice
                            fastcgi_param modHeadersAvailable true;

                            # Enable pretty urls
                            fastcgi_param front_controller_active true;
                            fastcgi_pass php-handler;
                            fastcgi_intercept_errors on;
                            fastcgi_request_buffering off;
                          '';
                        "~ ^/(?:updater|oc[ms]-provider)(?:$|/)" = {
                          index = "index.php";
                          tryFiles = "$uri/ =404";
                        };

                        "~ .(?:css|js|woff2?|svg|gif|map)$" = {
                          tryFiles = "$uri /index.php$request_uri";
                          extraConfig = ''
                            add_header Cache-Control "public, max-age=15778463";
                            add_header Referrer-Policy "no-referrer" always;
                            add_header X-Content-Type-Options "nosniff" always;
                            add_header X-Download-Options "noopen" always;
                            add_header X-Frame-Options "SAMEORIGIN" always;
                            add_header X-Permitted-Cross-Domain-Policies "none" always;
                            add_header X-Robots-Tag "none" always;
                            add_header X-XSS-Protection "1; mode=block" always;
                            access_log off;
                          '';
                        };
                        "~ .(?:png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm)$" = {
                          tryFiles = "$uri /index.php$request_uri";
                          extraConfig = "access_log off;";
                        };
                      };
                    };
                  };
                };
              };
            };
            service = {
              # useHostStore = true;
              ports = [ "${toString cfg.port}:80" ];
              healthcheck = {
                test = [
                  "CMD"
                  ''
                    curl -sSf 'http://localhost/status.php' | grep '"installed":true' | grep '"maintenance":false' | grep '"needsDbUpgrade":false' || exit 1''
                ];
                start_period = "20s";
                interval = "30s";
                timeout = "3s";
                retries = 5;
              };
              depends_on = [ "nextcloud" ];
            };
          };
        };
      };
    in { imports = [ image ]; };
  };
}
