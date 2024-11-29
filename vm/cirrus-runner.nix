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
    version = "22729156d1e508ec16b1bc98f59d1ffc6249927e";
    src = pkgs.fetchFromGitHub {
      owner = "0xb10c";
      repo = "cirrus-cli";
      rev = version;
      sha256 = "sha256-+BjY0oNkVcwttT8gfXZm0vWLOyGJyEjypIKl144ADUg=";
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

    # TODO: we can probably hardcode this
    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/cirrus/worker.yml";
      description = "The path to a cirrus worker configuration file, which contains, for example, the cirrus token. This file must only be readable by root.";
    };

    # can probably be hardcoded
    user = lib.mkOption {
      type = lib.types.str;
      default = "cirrus-worker";
      description = "The user the cirrus worker should run under.";
    };

    # can be hardcoded
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
      # TODO: more hardening!!
      serviceConfig = {
        ExecStart = "${pkgs.bash}/bin/bash -c '${patched-cirrus-cli}/bin/cirrus worker run --file ${CONFIG_FILE_PATH} --name ${cfg.name}-ephemeral --labels type=small --ephemeral'";
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'sleep 2 && ${pkgs.coreutils}/bin/rm ${CONFIG_FILE_PATH} && echo \"removed cirrus worker config file ${CONFIG_FILE_PATH}\"'";
        ExecStopPost = [
          # after the process ended, wait 5 seconds and then shut down the VM
          "${pkgs.bash}/bin/bash -c 'sleep 5 && /run/wrappers/bin/vm-shutdown now'"
        ];
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = CIRRUS_WORKER_HOME;
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
        DOCKER_HOST="unix:///run/user/8333/docker.sock";
        # The host has a big ccache. Use it in during the build.
        CCACHE_DIR = "/ci_container_base/ccache";
        # The host is managing the ccache size and trimming. Don't
        # try to do it in the VM (0 sets no-limit).
        CCACHE_MAXSIZE = "0";
        # By default, the CI will cache depends (sources & built) and
        # prev_releases in docker volumes. However, the VMs are ephemeral
        # and we don't keep the docker volumes. Rather, use 'bind' mounts
        # to folders on the "disk". These folders are mounted on /cache
        # and are symlinked to the expected locations below.    
        DANGER_CI_ON_HOST_CACHE_FOLDERS = "true";
        # Set the extra docker build arguments to cache the build steps
        DOCKER_BUILD_CACHE_HOST_DIR = "/cache/docker";
      };
    };

    # create a setuid wrapper for systemd-poweroff. This allows the
    # unprivileged cirrus-worker user to shutdown the VM after the
    # job finishes.
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
      uid = 8333;
      shell = pkgs.bash;
      # linger is needed for rootless docker
      linger = true;
      # subUidRanges and subGidRanges are needed for rootless docker
      subUidRanges = [
        { startUid = 100000; count = 65536; }
      ];
      subGidRanges = [
        { startGid = 100000; count = 65536; }
      ];
    };
    users.groups."${cfg.group}" = {      
      gid = 8333;
    };

    # the /perist mount from the host is only read/writable by
    # root. A bind mount to /cache for the cirrus-worker user
    # makes it read/writable for the cirrus-worker user too.
    systemd.services.bindfs-cache-mount = {
      description = "bindfs mount for /cache";
      after = [ "local-fs.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.bindfs}/bin/bindfs --force-user=${cfg.user} --force-group=${cfg.group} /persist /cache";
        ExecStop = "umount /cache";
        RemainAfterExit = true;
      };
    };

    systemd.tmpfiles.rules = [
      # Create the home directory of the cirrus-worker.
      "d '${CIRRUS_WORKER_HOME}'                0700 ${cfg.user} ${cfg.group} -"
      # Create the working directory of the CI.
      "d '/ci_container_base'                   0700 ${cfg.user} ${cfg.group} -"
      "d '/cache'                               0700 ${cfg.user} ${cfg.group} -"
      # Symlink the working directories to the persistent counterparts.
      "L '/ci_container_base/depends'           -    -           -            -  /cache/depends/"
      "L '/ci_container_base/prev_releases'     -    -           -            -  /cache/prev_releases"
      "L '/ci_container_base/ccache'            -    -           -            -  /cache/ccache"
    ];
  };
}
