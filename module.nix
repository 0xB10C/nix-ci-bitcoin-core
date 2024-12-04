{
  pkgs,
  lib,
  config,
  microvm,
  ...
}:

let
  cacheDir = "/data/cache";

  mkVM = (import ./vm/vm.nix { inherit pkgs config microvm; });
  cfg = config.services.cirrus-ephemeral-vm-runner;
  vmList =
    (builtins.genList (i: {
      id = i;
      name = "vm${toString i}s";
      size = "small";
    }) cfg.vms.small.count)
    ++ (builtins.genList (i: {
      id = i + cfg.vms.small.count;
      name = "vm${toString (i + cfg.vms.small.count)}m";
      size = "medium";
    }) cfg.vms.medium.count);
in
{

  imports = [
    ./host/monitoring.nix
  ];

  options = {
    services.cirrus-ephemeral-vm-runner = {
      enable = lib.mkEnableOption "cirrus CI ephemeral VM runner";

      name = lib.mkOption {
        type = lib.types.str;
        default = null;
        example = "b10c-ci-runner";
        description = ''
          Name of the host. Will be used as hostname and shown in the cirrus.com pool.
        '';
      };

      vms = {
        small = {
          count = lib.mkOption {
            type = lib.types.ints.u8;
            default = 0;
            example = 1;
            description = ''
              Number of small VMs.
            '';
          };
          memory = lib.mkOption {
            type = lib.types.ints.between 1 32;
            default = 8;
            example = 1;
            description = ''
              Memory in GB each small VM should have. The total (including medium VMs) should
              not be larger than the host memory size.
            '';
          };
          cpu = lib.mkOption {
            type = lib.types.ints.between 1 256;
            default = 2;
            example = 4;
            description = ''
              CPU cores each small VM should have.
            '';
          };
        };

        medium = {
          count = lib.mkOption {
            type = lib.types.ints.u8;
            default = 0;
            example = 1;
            description = ''
              Number of medium VMs.
            '';
          };
          memory = lib.mkOption {
            type = lib.types.ints.between 1 32;
            default = 12;
            example = 1;
            description = ''
              Memory in GB each medium VM should have. The total (including small VMs) should
              not be larger than the host memory size.
            '';
          };
          cpu = lib.mkOption {
            type = lib.types.ints.between 1 256;
            default = 4;
            example = 8;
            description = ''
              CPU cores each medium VM should have.
            '';
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # builds an ssh config file for the VMs
    # allowing easy ssh access to debug the VMs
    programs.ssh.extraConfig = lib.concatStrings (
      map (vm: ''
        Host ${vm.name}
          HostName 127.0.0.1
          Port ${toString (2000 + vm.id)}
          User root
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
      '') vmList
    );

    # defines overlay mounts for the VMs
    # These overlays are 'partOf' the microVM service
    # for each VM and are restarted (and re-created) each
    # time the VM is restarted. This is needed to ensure
    # the overlayFS is still properly mounted.
    # The clean-overlay-merged-dir-vm* services (see below)
    # will clean the merged dir up before it's re-mounted.
    systemd.mounts = (
      map (vm: {
        enable = true;
        where = "/data/overlay/${vm.name}/merged";
        type = "overlay";
        what = "overlay";
        options = "lowerdir=${cacheDir},upperdir=/data/overlay/${vm.name}/upper,workdir=/data/overlay/${vm.name}/work";
        partOf = [ "microvm@${vm.name}.service" ];
        before = [ "microvm@${vm.name}.service" ];
        wantedBy = [ "multi-user.target" ];
      }) vmList
    );

    # create the actual microvm definitions for the VMs
    microvm.vms = builtins.trace (
      ''

        Deploying:

        - ${toString cfg.vms.small.count}x small VMs: using ${toString (cfg.vms.small.count * cfg.vms.small.cpu)} threads & ${toString (cfg.vms.small.count * cfg.vms.small.memory)} GB
        - ${toString cfg.vms.medium.count}x medium VMs: using ${toString (cfg.vms.medium.count * cfg.vms.medium.cpu)} threads & ${toString (cfg.vms.medium.count * cfg.vms.medium.memory)} GB
        TOTAL: ${toString (cfg.vms.small.count * cfg.vms.small.cpu + cfg.vms.medium.count * cfg.vms.medium.cpu)} threads & ${toString (cfg.vms.small.count * cfg.vms.small.memory + cfg.vms.medium.count * cfg.vms.medium.memory)} GB
      ''
      )
      (
      builtins.listToAttrs (map (vm: {
        name = vm.name;
        value = mkVM {
          id = vm.id;
          name = vm.name;
          size = vm.size;
          runner_name = cfg.name;
          memory = cfg.vms."${vm.size}".memory;
          cpu = cfg.vms."${vm.size}".cpu;
        };
      }) vmList)
    );

    systemd.services =
      (builtins.listToAttrs (map (vm: {
        name = "microvm@${vm.name}";
        value = {
          after = [ "data-overlay-${vm.name}-merged.mount" ];
          requires = [ "data-overlay-${vm.name}-merged.mount" ];
          serviceConfig = {
            # before the VM starts, remove all disk images
            ExecStartPre = [
              "${pkgs.writeShellScript "start-pre-cleaning-up-cache.sh" ''
                echo "running start-pre-cleaning-up-cache.sh for ${vm.name}"
                SOURCE="/data/vm-cache/${vm.name}"
                if [ -d "$SOURCE" ]; then
                  echo "cleaning up files in $SOURCE"
                  rm -rf $SOURCE/*
                  echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
                fi
              ''}"
              "${pkgs.writeShellScript "start-pre-cleaning-up-disk-images.sh" ''
                echo "running start-pre-cleaning-up-disk-images.sh for ${vm.name}"
                rm /var/lib/microvms/${vm.name}/*.img || true
              ''}"
            ];

            # after the VM stops, copy cache data and clean up
            ExecStopPost = [
              "${pkgs.writeShellScript "copy-new-ccache-entries.sh" ''
                echo "running 01 copy-new-ccache-entries.sh for ${vm.name}"
                SOURCE="/data/vm-cache/${vm.name}/ccache"
                DEST="${cacheDir}/ccache"
                if [ -d "$SOURCE" ]; then
                  echo "removing lock and stats files from $SOURCE"
                  rm -rf $SOURCE/lock
                  rm -rf $SOURCE/*/stats
                  rm -rf $SOURCE/*/*/stats
                  echo "copying non-existing ccache files from $SOURCE to $DEST"
                  cp -n -R $SOURCE/* $DEST/ --verbose
                fi
              ''}"
              "${pkgs.writeShellScript "copy-new-built-depends.sh" ''
                echo "running 02 copy-new-built-depends.sh for ${vm.name}"
                SOURCE="/data/vm-cache/${vm.name}/depends/built"
                DEST="${cacheDir}/depends/built"
                if [ -d "$SOURCE" ]; then
                  echo "copying newly built depends from $SOURCE to $DEST"
                  cp -n -R $SOURCE/* $DEST/ --verbose
                fi
              ''}"
              "${pkgs.writeShellScript "copy-new-depends-sources.sh" ''
                echo "running 03 copy-new-depends-sources.sh for ${vm.name}"
                SOURCE="/data/vm-cache/${vm.name}/depends/sources/"
                DEST="${cacheDir}/depends/sources/"
                if [ -d "$SOURCE" ]; then
                  echo "copying new depends sources from $SOURCE to $DEST"
                  cp -n -R $SOURCE/* $DEST/ --verbose
                fi
              ''}"
              "${pkgs.writeShellScript "copy-new-prev_releases.sh" ''
                echo "running 04 copy-new-prev_releases.sh for ${vm.name}"
                SOURCE="/data/vm-cache/${vm.name}/prev_releases/*"
                DEST="${cacheDir}/prev_releases/"
                if [ -d "$SOURCE" ]; then
                  echo "copying new prev_releases files from $SOURCE to $DEST"
                  cp -n -R $SOURCE/* $DEST/ --verbose
                fi
              ''}"
              "${pkgs.writeShellScript "move-docker-image-cache.sh" ''
                echo "running 05 move-docker-image-cache.sh for ${vm.name}"
                set -o xtrace
                SOURCE="/data/vm-cache/${vm.name}/docker"
                DEST="${cacheDir}/docker/"
                if [ -d "$SOURCE" ]; then
                  for path in "$SOURCE"/*; do
                    image=$(basename "$path")
                    if [ -d "$SOURCE/$image" ]; then
                      if [ -e "$SOURCE/$image/index.json" ]; then
                        echo "removing existing cache for: $image"
                        rm -rf "$DEST/$image" --verbose
                        echo "moving docker files from $SOURCE/$image to $DEST"
                        mv "$SOURCE/$image" "$DEST" --verbose
                      fi
                    fi
                  done
                fi
              ''}"
              "${pkgs.writeShellScript "cleaning-up-cache.sh" ''
                echo "running 06 cleaning-up-cache.sh for ${vm.name}"
                SOURCE="/data/vm-cache/${vm.name}"
                if [ -d "$SOURCE" ]; then
                  echo "cleaning up files in $SOURCE"
                  rm -rf $SOURCE/*
                  echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
                fi
              ''}"
            ];
          };
        };
      }) vmList))
      // (builtins.listToAttrs (map (vm: {
        name = "bindfs-mount-upper-${vm.name}";
        value = {
          description = "bindfs mount owned by microvm for the ${vm.name}'s /cache dir";
          after = [ "local-fs.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStartPre = [
              "${pkgs.writeShellScript "create-${vm.name}-cache-dir.sh" ''
                echo "creating vm-cache dir for ${vm.name}"
                mkdir -p /data/vm-cache/${vm.name}
                chown microvm:kvm /data/vm-cache/${vm.name} -R
                chmod 700 /data/vm-cache/${vm.name} -R
              ''}"
            ];
            ExecStart = "${pkgs.bindfs}/bin/bindfs --force-user=microvm /data/overlay/${vm.name}/upper/ /data/vm-cache/${vm.name}";
            ExecStop = "umount /data/vm-cache/${vm.name}";
            RemainAfterExit = true;
          };
        };
      }) vmList))
      // (builtins.listToAttrs (map (vm: {
        name = "clean-overlay-merged-dir-${vm.name}";
        value = {
          description = "Clean /data/overlay/${vm.name}/merged before mounting";
          wantedBy = [ "data-overlay-${vm.name}-merged.mount" ]; # Ensure this runs before the mount
          before = [ "data-overlay-${vm.name}-merged.mount" ];
          script = ''
            SOURCE="/data/overlay/${vm.name}/merged"
            if [ -d "$SOURCE" ]; then
              echo "cleaning up files in $SOURCE"
              rm -rf $SOURCE/*
              echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
            fi
          '';
          serviceConfig = {
            Type = "oneshot";
          };
        };
      }) vmList));

    systemd.tmpfiles.settings = (
      builtins.listToAttrs (map (vm: {
        name = "${vm.name}";
        value = {
          "/data/vm-cache/${vm.name}/" = {
            d = {
              user = "microvm";
              group = "kvm";
              mode = "0700";
            };
          };
          "/data/overlay/${vm.name}/upper/" = {
            d = {
              user = "root";
              group = "root";
              mode = "0700";
            };
          };
          "/data/overlay/${vm.name}/work" = {
            d = {
              user = "root";
              group = "root";
              mode = "0700";
            };
          };
        };
      }) vmList)
    );

    systemd.tmpfiles.rules = [
      "d '${cacheDir}'                 0700 'microvm' 'root' - -"
      "d '${cacheDir}/depends'         0700 'microvm' 'root' - -"
      "d '${cacheDir}/depends/built'   0700 'microvm' 'root' - -"
      "d '${cacheDir}/depends/sources' 0700 'microvm' 'root' - -"
      "d '${cacheDir}/ccache'          0700 'microvm' 'root' - -"
      "d '${cacheDir}/prev_releases'   0700 'microvm' 'root' - -"
      "d '${cacheDir}/docker'          0700 'microvm' 'root' - -"
    ];

    services.prometheus.scrapeConfigs = (
      map (vm: {
        job_name = vm.name;
        static_configs = [ { targets = [ "127.0.0.1:${toString (9500 + vm.id)}" ]; } ];
      }) vmList
    );

    environment.systemPackages = [
      pkgs.htop
      pkgs.vim
      pkgs.tree
    ];

  };
}
