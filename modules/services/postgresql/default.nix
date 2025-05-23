{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.services.postgresql;

  postgresql =
    if cfg.extraPlugins == []
      then cfg.package
      else cfg.package.withPackages (_: cfg.extraPlugins);

  toStr = value:
    if true == value then "yes"
    else if false == value then "no"
    else if isString value then "'${lib.replaceStrings ["'"] ["''"] value}'"
    else toString value;

  # The main PostgreSQL configuration file.
  configFile = pkgs.writeTextDir "postgresql.conf" (concatStringsSep "\n" (mapAttrsToList (n: v: "${n} = ${toStr v}") cfg.settings));

  configFileCheck = pkgs.runCommand "postgresql-configfile-check" {} ''
    ${cfg.package}/bin/postgres -D${configFile} -C config_file >/dev/null
    touch $out
  '';

  groupAccessAvailable = versionAtLeast postgresql.version "11.0";

in

{
  imports = [
    (mkRemovedOptionModule [ "services" "postgresql" "extraConfig" ] "Use services.postgresql.settings instead.")
  ];

  ###### interface

  options = {

    services.postgresql = {

      enable = mkEnableOption "PostgreSQL Server";

      package = mkOption {
        type = types.package;
        example = literalExpression "pkgs.postgresql_11";
        description = ''
          PostgreSQL package to use.
        '';
      };

      port = mkOption {
        type = types.int;
        default = 5432;
        description = ''
          The port on which PostgreSQL listens.
        '';
      };

      checkConfig = mkOption {
        type = types.bool;
        default = true;
        description = "Check the syntax of the configuration file at compile time";
      };

      dataDir = mkOption {
        type = types.path;
        defaultText = literalExpression ''"/var/lib/postgresql/''${config.services.postgresql.package.psqlSchema}"'';
        example = "/var/lib/postgresql/11";
        description = ''
          The data directory for PostgreSQL. If left as the default value
          this directory will automatically be created before the PostgreSQL server starts, otherwise
          the sysadmin is responsible for ensuring the directory exists with appropriate ownership
          and permissions.
        '';
      };

      authentication = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Defines how users authenticate themselves to the server. See the
          [
          PostgreSQL documentation for pg_hba.conf](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html)
          for details on the expected format of this option. By default,
          peer based authentication will be used for users connecting
          via the Unix socket, and md5 password authentication will be
          used for users connecting via TCP. Any added rules will be
          inserted above the default rules. If you'd like to replace the
          default rules entirely, you can use `lib.mkForce` in your
          module.
        '';
      };

      identMap = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Defines the mapping from system users to database users.

          The general form is:

          map-name system-username database-username
        '';
      };

      initdbArgs = mkOption {
        type = with types; listOf str;
        default = [];
        example = [ "--data-checksums" "--allow-group-access" ];
        description = ''
          Additional arguments passed to `initdb` during data dir
          initialisation.
        '';
      };

      initialScript = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          A file containing SQL statements to execute on first startup.
        '';
      };

      ensureDatabases = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Ensures that the specified databases exist.
          This option will never delete existing databases, especially not when the value of this
          option is changed. This means that databases created once through this option or
          otherwise have to be removed manually.
        '';
        example = [
          "gitea"
          "nextcloud"
        ];
      };

      ensureUsers = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = ''
                Name of the user to ensure.
              '';
            };
            ensurePermissions = mkOption {
              type = types.attrsOf types.str;
              default = {};
              description = ''
                Permissions to ensure for the user, specified as an attribute set.
                The attribute names specify the database and tables to grant the permissions for.
                The attribute values specify the permissions to grant. You may specify one or
                multiple comma-separated SQL privileges here.

                For more information on how to specify the target
                and on which privileges exist, see the
                [GRANT syntax](https://www.postgresql.org/docs/current/sql-grant.html).
                The attributes are used as `GRANT ''${attrValue} ON ''${attrName}`.
              '';
              example = literalExpression ''
                {
                  "DATABASE \"nextcloud\"" = "ALL PRIVILEGES";
                  "ALL TABLES IN SCHEMA public" = "ALL PRIVILEGES";
                }
              '';
            };
          };
        });
        default = [];
        description = ''
          Ensures that the specified users exist and have at least the ensured permissions.
          The PostgreSQL users will be identified using peer authentication. This authenticates the Unix user with the
          same name only, and that without the need for a password.
          This option will never delete existing users or remove permissions, especially not when the value of this
          option is changed. This means that users created and permissions assigned once through this option or
          otherwise have to be removed manually.
        '';
        example = literalExpression ''
          [
            {
              name = "nextcloud";
              ensurePermissions = {
                "DATABASE nextcloud" = "ALL PRIVILEGES";
              };
            }
            {
              name = "superuser";
              ensurePermissions = {
                "ALL TABLES IN SCHEMA public" = "ALL PRIVILEGES";
              };
            }
          ]
        '';
      };

      enableTCPIP = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether PostgreSQL should listen on all network interfaces.
          If disabled, the database can only be accessed via its Unix
          domain socket or via TCP connections to localhost.
        '';
      };

      logLinePrefix = mkOption {
        type = types.str;
        default = "[%p] ";
        example = "%m [%p] ";
        description = ''
          A printf-style string that is output at the beginning of each log line.
          Upstream default is `'%m [%p] '`, i.e. it includes the timestamp. We do
          not include the timestamp, because journal has it anyway.
        '';
      };

      extraPlugins = mkOption {
        type = types.listOf types.path;
        default = [];
        example = literalExpression "with pkgs.postgresql_11.pkgs; [ postgis pg_repack ]";
        description = ''
          List of PostgreSQL plugins. PostgreSQL version for each plugin should
          match version for `services.postgresql.package` value.
        '';
      };

      settings = mkOption {
        type = with types; attrsOf (oneOf [ bool float int str ]);
        default = {};
        description = ''
          PostgreSQL configuration. Refer to
          <https://www.postgresql.org/docs/11/config-setting.html#CONFIG-SETTING-CONFIGURATION-FILE>
          for an overview of `postgresql.conf`.

          ::: {.note}

          String values will automatically be enclosed in single quotes. Single quotes will be
          escaped with two single quotes as described by the upstream documentation linked above.

          :::
        '';
        example = literalExpression ''
          {
            log_connections = true;
            log_statement = "all";
            logging_collector = true
            log_disconnections = true
            log_destination = lib.mkForce "syslog";
          }
        '';
      };

      recoveryConfig = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          Contents of the {file}`recovery.conf` file.
        '';
      };

      superUser = mkOption {
        type = types.str;
        default = "postgres";
        internal = true;
        readOnly = true;
        description = ''
          PostgreSQL superuser account to use for various operations. Internal since changing
          this value would lead to breakage while setting up databases.
        '';
        };
    };

  };

  ###### implementation

  config = mkIf cfg.enable {

    # FIXME: implement. I didn't implement these because they require some
    # sort of postStart facility, which launchd does not provide.
    #
    # one could perhaps trigger another agent by the existing agent, but
    # I couldn't find how to do that.
    warnings = if cfg.initialScript != null
      || cfg.ensureDatabases != []
      || cfg.ensureUsers != []
      then [''
        Currently nix-darwin does not support postgresql initialScript,
        ensureDatabases, or ensureUsers
      '']
      else [];

    services.postgresql.settings =
      {
        hba_file = "${pkgs.writeText "pg_hba.conf" cfg.authentication}";
        ident_file = "${pkgs.writeText "pg_ident.conf" cfg.identMap}";
        log_destination = "stderr";
        log_line_prefix = cfg.logLinePrefix;
        listen_addresses = if cfg.enableTCPIP then "*" else "localhost";
        port = cfg.port;
      };

    services.postgresql.package = let
        mkThrow = ver: throw "postgresql_${ver} was removed, please upgrade your postgresql version.";
    in
      # Note: when changing the default, make it conditional on
      # ‘system.stateVersion’ to maintain compatibility with existing
      # systems!
      mkDefault (if config.system.stateVersion >= 4 then pkgs.postgresql_14
            else mkThrow "9_6");

    services.postgresql.dataDir = mkDefault "/var/lib/postgresql/${cfg.package.psqlSchema}";

    services.postgresql.authentication = mkAfter
      ''
        # Generated file; do not edit!
        local all all              peer
        host  all all 127.0.0.1/32 md5
        host  all all ::1/128      md5
      '';

    environment.systemPackages = [ postgresql ];

    environment.pathsToLink = [
     "/share/postgresql"
    ];

    # FIXME: implement system.extraDependencies to do this less sketchily
    # system.extraDependencies = lib.optional (cfg.checkConfig && pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform) configFileCheck;

    launchd.user.agents.postgresql =
      { path = [ postgresql ];
        script = ''
          # FIXME: ${if cfg.checkConfig then configFileCheck else ""}

          if ! test -e ${cfg.dataDir}/PG_VERSION; then
            # Cleanup the data directory.
            ${pkgs.coreutils}/bin/rm -f ${cfg.dataDir}/*.conf

            # Initialise the database.
            ${postgresql}/bin/initdb -U ${cfg.superUser} ${concatStringsSep " " cfg.initdbArgs}

            # See postStart!
            # FIXME: implement postStart
            # touch "${cfg.dataDir}/.first_startup"
          fi

          ${pkgs.coreutils}/bin/ln -sfn ${configFile}/postgresql.conf ${cfg.dataDir}/postgresql.conf
          ${optionalString (cfg.recoveryConfig != null) ''
            ${pkgs.coreutils}/bin/ln -sfn "${pkgs.writeText "recovery.conf" cfg.recoveryConfig}" \
              "${cfg.dataDir}/recovery.conf"
          ''}

          exec ${postgresql}/bin/postgres
        '';

        serviceConfig.KeepAlive = true;
        serviceConfig.RunAtLoad = true;
        serviceConfig.EnvironmentVariables = {
          PGDATA = cfg.dataDir;
        };
        managedBy = "services.postgresql.enable";
      };

  };
}
