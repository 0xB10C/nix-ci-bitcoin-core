{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.cirrus-runner;
  CONFIG_FILE_PATH = "/var/lib/cirrus-worker/worker.yml";

  CIRRUS_WORKER_HOME = "/var/lib/cirrus-worker";

  patched-cirrus-cli = pkgs.cirrus-cli.overrideAttrs (oldAttrs: rec {
    version = "9885ae3dadc5b8656c8e1d5e61b7de5020510d88";
    src = pkgs.fetchFromGitHub {
      owner = "0xb10c";
      repo = "cirrus-cli";
      rev = "a8d7ba7b20a11f22008d9b53b41858fad93fdc7c";
      sha256 = "sha256-aP3aOIVcnCfLzZ/ED6iZ610KCUoWTXUx8HcWG6AdHWY=";
    };
    vendorHash = "sha256-+OMhaAGA+pmiDUyXDo9UfQ0SFEAN9zuNZjnLkgr7a+0=";
  });
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
        if [ "$FILE_PERMS" != "600" ]; then
          echo "${cfg.configFile} permissions are not restricted to read-only by root: 0600 (permissions: $FILE_PERMS)"
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
      after = [
        "network.target"
        "docker.service"
        "setup-cirrus-worker-config.service"
      ];
      wants = [
        "setup-cirrus-worker-config.service"
        "docker.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${patched-cirrus-cli}/bin/cirrus worker run --file ${CONFIG_FILE_PATH} --name ${cfg.name} --labels type=small --single-task";
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'sleep 2 && ${pkgs.coreutils}/bin/rm ${CONFIG_FILE_PATH} && echo \"removed cirrus worker config file ${CONFIG_FILE_PATH}\"'";
        ExecStopPost = "${pkgs.bash}/bin/bash -c 'sleep 5 && /run/wrappers/bin/vm-shutdown now'";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/var/lib/cirrus-worker";
      };
      environment = {
        XDG_CACHE_HOME = "/var/lib/cirrus-worker/.cache";
        PATH = lib.mkForce (
          lib.makeBinPath [
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.systemd
            pkgs.cirrus-cli
            pkgs.docker
            pkgs.python3
            pkgs.git
            pkgs.podman
          ]
        );
        DOCKER_HOST = "unix:///var/run/docker.sock";
        RESTART_CI_DOCKER_BEFORE_RUN = "1";
        # The host has a big ccache. Use it in during the build.
        CCACHE_REMOTE_STORAGE = "http://10.0.2.10:8000/cache/";
        # By default, the CI will cache depends (sources & built) and
        # prev_releases in docker volumes. However, the VMs are ephemeral
        # and we don't keep the docker volumes. Rather, use 'bind' mounts
        # to folders on the disk - these folders are set up below.   
        DANGER_CI_ON_HOST_CACHE_FOLDERS = "true";
      };
    };

    security.wrappers = {
      vm-shutdown = {
        setuid = true;
        owner = "root";
        group = "root";
        source = "${pkgs.systemd}/bin/poweroff";
      };
    };

    users.users."${cfg.user}" = {
      isSystemUser = true;
      group = cfg.group;
      description = "Cirrus CI worker user";
      home = CIRRUS_WORKER_HOME;
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "docker" ];
    };
    users.groups."${cfg.group}" = { };

    systemd.tmpfiles.rules = [
      # Create the home directory of the cirrus-worker.
      "d '${CIRRUS_WORKER_HOME}'                0700 ${cfg.user} ${cfg.group} -"
      # Create the working directory of the CI and the depends directory inside of it.
      "d '/ci_container_base'                   0700 ${cfg.user} ${cfg.group} -"
      "d '/ci_container_base/depends'           0700 ${cfg.user} ${cfg.group} -"
      # Create and make cirrus-worker the owner of the persisted depends and releases directories. 
      "d '/persist/prev_releases'               0700 ${cfg.user} ${cfg.group} -"
      "d '/persist/depends/sources'             0700 ${cfg.user} ${cfg.group} -"
      "d '/persist/depends/built'               0700 ${cfg.user} ${cfg.group} -"
      # While cirrus-worker is the owner of these, also recursively set the file and
      # directory attributes to +i (immutable). With the effect that the cirrus-worker
      # can create new files, but can't overwrite or delete existing files. This serves
      # as protection against a mallicous CI job deleting the cached depends. 
      "H '/persist/prev_releases'               -    -           -            -  +i"
      "H '/persist/depends/built'               -    -           -            -  +i"
      "H '/persist/depends/sources'             -    -           -            -  +i"
      # Symlink the working directories to the persistent counterparts.
      "L '/ci_container_base/depends/sources'   -    -           -            -  /persist/depends/sources"
      "L '/ci_container_base/depends/built'     -    -           -            -  /persist/depends/built"
      "L '/ci_container_base/prev_releases'     -    -           -            -  /persist/prev_releases"
    ];
  };
}
