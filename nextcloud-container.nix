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

    hostname = mkOption {
      type = str;
      description = "Hostname at which the server is available.";
    };

    package = mkOption {
      type = package;
      description = "NextCloud package to use.";
    };

    extra-apps = mkOption {
      type = listOf package;
      description = "List of other apps to enable.";
      default = [ ];
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
        "d ${cfg.state-directory}/home     0700 nextcloud root - -"
        "d ${cfg.state-directory}/data     0700 nextcloud root - -"
        "d ${cfg.state-directory}/postgres 0700 nextcloud root - -"
      ];
    };

    users.users = {
      nextcloud = {
        isSystemUser = true;
        group = "nextcloud";
        uid = cfg.uids.nextcloud;
      };
    };

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
                services = {
                  nscd.enable = false;
                  postgresql.enable = true;
                  nextcloud = {
                    enable = true;
                    package = cfg.package;
                    hostName = cfg.hostname;
                    home = "/var/lib/nextcloud/home";
                    datadir = "/var/lib/nextcloud/data";
                    configureRedis = true;
                    extraAppsEnable = true;
                    extraApps = cfg.extra-apps;
                    enableBrokenCiphersForSSE = false;
                    database.createLocally = true;
                    config = {
                      dbtype = "pgsql";
                      adminpassFile = "/run/nextcloud/admin.passwd";
                    };
                  };
                };
              };
            };
            service = {
              restart = "always";
              volumes = [
                "${cfg.state-directory}/home:/var/lib/nextcloud/home"
                "${cfg.state-directory}/data:/var/lib/nextcloud/data"
                "${hostSecrets.nextcloudAdminPasswd.target-file}:/run/nextcloud/admin.passwd:ro,Z"
                "${cfg.state-directory}/postgres:/var/lib/postgresql/data"
              ];
              user = mkUserMap cfg.uids.nextcloud;
              depends_on = [ "postgres" ];
              ports = [ "${cfg.port}:80" ];
            };
          };
        };
      };
    in { imports = [ image ]; };
  };
}
