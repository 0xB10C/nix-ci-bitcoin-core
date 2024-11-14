{ pkgs, lib, config, ... }:
let 
  cfg = config.services.cirrus-runner;
  CONFIG_FILE_PATH = "/var/lib/cirrus-worker/worker.yml"; 
in
{

  options.services.cirrus-runner = {
    enable = lib.mkEnableOption "enable the cirrus runner";

    name = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "The name of the cirrus worker.";
    };
       
    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/cirrus/worker.yml";
      description = "The path to a cirrus worker configuration file, which contains, for example, the cirrus token. This file must only be readable by root.";
    };
    
    ccacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/ccache/";
      description = "The path to a read and writeable directory for a ccache. Most exist.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "cirrus-worker";
      description = "The user the cirrus worker should run under.";
    };
    
    group = lib.mkOption {
      type = lib.types.str;
      default = "cirrus-worker";
      description = "The group the cirrus worker should run under.";
    };
        
  };

  config = lib.mkIf cfg.enable {

    # The cirrus worker gets its own temporary copy of the configuration file.
    # This file is removed after cirrus-cli has read it to ensure a CI script
    # can't read it, which would expose the runner token allowing to spawn
    # mallicious workers.
    systemd.services.setup-cirrus-worker-config = {
      description = "Cirrus CI worker config creation";
      after = [ "network.target" ];
      wantedBy = [ "cirrus-worker.service" ];
      script = ''
        # To protect against set up errors, check that the
        # file is only readable by root. Otherwise, don't
        # copy the config file.
        FILE_OWNER=$(stat -c "%U" "${cfg.configFile}")
        FILE_PERMS=$(stat -c "%a" "${cfg.configFile}")
        if [ "$FILE_OWNER" != "root" ]; then
          echo "${cfg.configFile} is not owned by root (owner is $FILE_OWNER)"
          exit 1
        fi        
        if [ "$FILE_PERMS" != "400" ]; then
          echo "${cfg.configFile} permissions are not restricted to read-only by root: 0400 (permissions: $FILE_PERMS)"
          exit 1
        fi

        cp ${cfg.configFile} ${CONFIG_FILE_PATH}
        chown ${cfg.user}:${cfg.group} ${CONFIG_FILE_PATH}
        chmod 600 ${CONFIG_FILE_PATH}
        echo "Copied cirrus worker config file to ${CONFIG_FILE_PATH} read-writable by ${cfg.user}:${cfg.group}"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root"; # only root can read the config file
      };
    };
    
    systemd.services.cirrus-worker = {
      description = "Cirrus CI Worker";
      after = [ "network.target" "setup-cirrus-worker-config.service" ];
      wants = [ "setup-cirrus-worker-config.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.cirrus-cli}/bin/cirrus worker run --file ${CONFIG_FILE_PATH} --name ${cfg.name} --labels type=medium";
        ExecStartPost="${pkgs.bash}/bin/bash -c 'sleep 2 && ${pkgs.coreutils}/bin/rm ${CONFIG_FILE_PATH} && echo \"removed cirrus worker config file ${CONFIG_FILE_PATH}\"'";
        Restart = "always";
        User = cfg.user;
        Group = cfg.group;
        AmbientCapabilities="CAP_NET_ADMIN CAP_NET_RAW";
        CapabilityBoundingSet="CAP_NET_ADMIN CAP_NET_RAW";
        WorkingDirectory = "/var/lib/cirrus-worker";
      };
      environment = {
        XDG_CACHE_HOME = "/var/lib/cirrus-worker/.cache";
        PATH = lib.mkForce (lib.makeBinPath [
          pkgs.bash
          pkgs.coreutils
          pkgs.cloud-hypervisor
          # pkgs.findutils
          # pkgs.gnugrep
          # pkgs.gnused
          # pkgs.systemd
          # pkgs.cirrus-cli
          # pkgs.docker
          # pkgs.python3
          # pkgs.git
          # pkgs.podman
          (pkgs.callPackage ./vetu.nix {})
        ]);
        DOCKER_HOST = "unix:///var/run/docker.sock";
        RESTART_CI_DOCKER_BEFORE_RUN = "1";
        CCACHE_DIR = cfg.ccacheDir;
      };
    };

    users.users."${cfg.user}" = {
      isSystemUser = true;
      group = cfg.group;
      description = "Cirrus CI worker user";
      home = "/var/lib/cirrus-worker";
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "docker" ];
    };
    users.groups."${cfg.group}" = {};

    systemd.tmpfiles.rules = [
      "d /var/lib/cirrus-worker 0700 ${cfg.user} ${cfg.group} -"
    ];
    
  };
}
