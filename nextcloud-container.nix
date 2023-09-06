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

    hostname = mkOption {
      type = str;
      description = "Hostname at which the server is available.";
    };

    package = mkOption {
      type = package;
      description = "NextCloud package to use.";
    };

    extra-apps = mkOption {
      type = attrsOf package;
      description = "List of other apps to enable.";
      default = { };
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
    fudo.secrets.host-secrets."${hostname}" = {
      nextcloudAdminPasswd = {
        source-file =
          pkgs.lib.passwd.stablerandom-passwd-file "nextcloud-admin-passwd"
          config.instance.build-seed;
        target-file = "/run/nextcloud/admin.passwd";
      };
    };

    virtualisation.arion.projects.nextcloud.settings = let
      image = { ... }: {
        project.name = "nextcloud";
        services = {
          nextcloud = { pkgs, lib, ... }: {
            nixos = {
              useSystemd = true;
              configuration = {
                boot.tmpOnTmpfs = true;
                system.nssModules = lib.mkForce [ ];
                environment.etc."nextcloud/admin.passwd" = {
                  source = "/run/nextcloud/admin.passwd";
                  mode = "0400";
                  user = "nextcloud";
                };
                systemd.tmpfiles.rules = [
                  "d /var/lib/nextcloud/data 0700 nextcloud root - -"
                  "d /var/lib/nextcloud/data/config 700 nextcloud root - -"
                  "d /var/lib/nextcloud/home 0755 nextcloud root - -"
                ];
                services = {
                  nscd.enable = false;
                  postgresql.enable = true;
                  nextcloud = {
                    enable = true;
                    package = cfg.package;
                    hostName = cfg.hostname;
                    home = "/var/lib/nextcloud/home";
                    datadir = "/var/lib/nextcloud/data";
                    webfinger = true;
                    configureRedis = true;
                    extraAppsEnable = true;
                    extraApps = cfg.extra-apps;
                    autoUpdateApps.enable = true;
                    appstoreEnable = false;
                    enableBrokenCiphersForSSE = false;
                    enableImageMagick = true;
                    database.createLocally = true;
                    nginx.recommendedHttpHeaders = true;
                    maxUploadSize = "4G";
                    https = true;
                    config = {
                      dbtype = "pgsql";
                      adminpassFile = "/etc/nextcloud/admin.passwd";
                      overwriteProtocol = "https";
                      extraTrustedDomains = [ "nextcloud.fudo.org" ];
                      defaultPhoneRegion = "CA";
                    };
                  };
                };
              };
            };
            service = {
              restart = "always";
              volumes = [
                "nextcloud-home:/var/lib/nextcloud/home"
                "nextcloud-data:/var/lib/nextcloud/data"
                "${hostSecrets.nextcloudAdminPasswd.target-file}:/run/nextcloud/admin.passwd:ro,Z"
                "postgres-data:/var/lib/postgresql"
              ];
              ports = [ "${toString cfg.port}:80" ];
            };
          };
        };
        docker-compose.volumes = {
          postgres-data = { };
          nextcloud-data = { };
          nextcloud-home = { };
        };
      };
    in { imports = [ image ]; };
  };
}
