{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.cirrus-runner;

  MOUNTED_CONFIG_FILE_PATH = "/etc/cirrus/worker.yml";
  VM_CONFIG_FILE_PATH = "/home/cirrus-worker/cirrus/worker.yml";

  CIRRUS_WORKER_HOME = "/home/cirrus-worker";
  CIRRUS_WORKER_USER = "cirrus-worker";
  CIRRUS_WORKER_GROUP = "cirrus-worker";

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

    size = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "The size (type) of the cirrus worker. Either small or medium.";
    };

  };

  config = lib.mkIf cfg.enable {

    # The cirrus worker gets its own temporary copy of the configuration file.
    # This file is removed after cirrus-cli has read it to ensure a CI script
    # can't read it, which would expose the runner token allowing to spawn
    # mallicious workers.
    systemd.services.setup-cirrus-worker-config = {
      description = "Cirrus CI worker config creation";
      after = [ "network-online.target" ];
      wants = [
        "network-online.target"
      ];
      wantedBy = [ "cirrus-worker.service" ];
      script = ''
        # To protect against set up errors, check that the
        # file is only readable by root. Otherwise, don't
        # copy the config file.
        FILE_OWNER=$(stat -c "%U" "${MOUNTED_CONFIG_FILE_PATH}")
        FILE_PERMS=$(stat -c "%a" "${MOUNTED_CONFIG_FILE_PATH}")
        if [ "$FILE_OWNER" != "root" ]; then
          echo "${MOUNTED_CONFIG_FILE_PATH} is not owned by root (owner is $FILE_OWNER)"
          exit 1
        fi
        if [ "$FILE_PERMS" != "600" ]; then
          echo "${MOUNTED_CONFIG_FILE_PATH} permissions are not restricted to read-only by root: 0600 (permissions: $FILE_PERMS)"
          exit 1
        fi

        cp ${MOUNTED_CONFIG_FILE_PATH} ${VM_CONFIG_FILE_PATH}
        chown ${CIRRUS_WORKER_USER}:${CIRRUS_WORKER_GROUP} ${VM_CONFIG_FILE_PATH}
        chmod 600 ${VM_CONFIG_FILE_PATH}
        echo "Copied cirrus worker config file to ${VM_CONFIG_FILE_PATH} read-writable by ${CIRRUS_WORKER_USER}:${CIRRUS_WORKER_GROUP}"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root"; # only root can read the config file
      };
    };

    systemd.services.cirrus-worker = {
      description = "Cirrus CI Worker";
      after = [
        "network-online.target"
        "setup-cirrus-worker-config.service"
      ];
      wants = [
        "network-online.target"
        "dockerd-rootless.service"
      ];
      wantedBy = [ "multi-user.target" ];
      # TODO: more hardening!!
      serviceConfig = {
        ExecStartPre = [
          "${pkgs.writeShellScript "wait-for-docker.sh" ''
            set -o xtrace
            FILE_TO_CHECK="/run/user/8333/docker.sock"
            # Number of attempts
            MAX_ATTEMPTS=20

            # Counter for attempts
            attempt=0

            while [[ $attempt -lt $MAX_ATTEMPTS ]]
            do
                if [[ -e "$FILE_TO_CHECK" ]]; then
                    echo "File exists: $FILE_TO_CHECK"
                    exit 0
                else
                    echo "Attempt $((attempt + 1)): File does not exist. Retrying in 1 second..."
                fi
                sleep 1
                ((attempt++))
            done
            exit 1
          ''}"
          "${pkgs.writeShellScript "load-docker-images.sh" ''
            set -o xtrace
            DIRECTORY="/cache/docker/base-imgs"
            # ensure we sort the base images. They start with the date they were
            # created, which means newer images are tagged later. This sets the
            # tag on the newer image (as the old tag is overwritten with the second)
            # `docker tag`
            export LC_COLLATE=C
            for FILE in $(ls "$DIRECTORY" | sort); do
              if [ -f "$DIRECTORY/$FILE" ]; then
                ${pkgs.docker}/bin/docker load --input $DIRECTORY/$FILE || true
                base=$(basename $FILE)
                id=$(echo $base | sed 's/\.tar//g' | ${pkgs.gawk}/bin/awk -F "+" '{print $4}')
                tag=$(echo $base | ${pkgs.gawk}/bin/awk -F "+" '{print $2 ":" $3}' | tr '@' '/')
                ${pkgs.docker}/bin/docker tag $id $tag || true
              fi
            done
          ''}"
        ];
        ExecStart = "${pkgs.bash}/bin/bash -c '${patched-cirrus-cli}/bin/cirrus worker run --file ${VM_CONFIG_FILE_PATH} --name ${cfg.name} --labels type=${cfg.size} --ephemeral'";
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'sleep 2 && ${pkgs.coreutils}/bin/rm ${VM_CONFIG_FILE_PATH} && echo \"removed cirrus worker config file ${VM_CONFIG_FILE_PATH}\"'";
        ExecStopPost = [
          "${pkgs.writeShellScript "save-docker-images.sh" ''
            set -o xtrace
            images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "ci_")
            for image in $images; do
              creation_date=$(docker images --format '{{.CreatedAt}}' $image | ${pkgs.gawk}/bin/awk -F " " '{print $1}')
              repo_tag_id=$(docker images --format '{{.Repository}}+{{.Tag}}+{{.ID}}' $image | tr '/' '@')
              filename="$creation_date+$repo_tag_id.tar"
              if [ ! -f "/cache/docker/base-imgs/$filename" ]; then
                docker save -o "/cache/docker/base-imgs/$filename" "$image" && echo "Saved $image to $filename.tar"
              fi
            done
          ''}"
          # after the process ended, wait 5 seconds and then shut down the VM
          "${pkgs.bash}/bin/bash -c 'sleep 5 && /run/wrappers/bin/vm-shutdown now'"
        ];
        User = CIRRUS_WORKER_USER;
        Group = CIRRUS_WORKER_GROUP;
        WorkingDirectory = CIRRUS_WORKER_HOME;
        # Loading the docker images can take a while if all VMs load them at
        # the same time. To avoid the cirrus-worker failing to start, time out
        # only after 300 secs.
        TimeoutStartSec = "300";
      };
      environment = {
        XDG_CACHE_HOME = "${CIRRUS_WORKER_HOME}/.cache";
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
        DOCKER_BUILD_CACHE_HOST_DIR = "/cache/docker/ci-imgs";
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

    users.users."${CIRRUS_WORKER_USER}" = {
      isSystemUser = true;
      group = CIRRUS_WORKER_GROUP;
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
    users.groups."${CIRRUS_WORKER_GROUP}" = {
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
        ExecStart = "${pkgs.bindfs}/bin/bindfs --force-user=${CIRRUS_WORKER_USER} --force-group=${CIRRUS_WORKER_GROUP} /persist /cache";
        ExecStop = "umount /cache";
        RemainAfterExit = true;
      };
    };

    systemd.tmpfiles.rules = [
      # Create the home directory of the cirrus-worker.
      "d '${CIRRUS_WORKER_HOME}'                0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      "d '${CIRRUS_WORKER_HOME}/cirrus'         0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      # Create the working directory of the CI.
      "d '/ci_container_base'                   0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      "d '/cache'                               0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      # Symlink the working directories to the persistent counterparts.
      "L '/ci_container_base/depends'           -    -           -            -  /cache/depends/"
      "L '/ci_container_base/prev_releases'     -    -           -            -  /cache/prev_releases"
      "L '/ci_container_base/ccache'            -    -           -            -  /cache/ccache"
    ];
  };
}
