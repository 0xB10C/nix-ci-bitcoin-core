{
  pkgs,
  lib,
  config,
  modulesPath,
  ...
}:

let
  mkQemu = (import ./vm/vm.nix { inherit pkgs config modulesPath; });
  cacheDir = "/data/cache";
  cfg = config.services.cirrus-ephemeral-vm-runner;
  vmList =
    (builtins.genList (i: {
      id = i;
      name = "vm${toString i}small";
      size = "small";
    }) cfg.vms.small.count)
    ++ (builtins.genList (i: {
      id = i + cfg.vms.small.count;
      name = "vm${toString (i + cfg.vms.small.count)}medium";
      size = "medium";
    }) cfg.vms.medium.count);
in
{
  imports = [ ./host/monitoring.nix ];

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
          User alice
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
      '') vmList
    );

    # defines overlay mounts for the VMs
    # These overlays are 'partOf' the microVM service
    # for each VM and are restarted (and re-created) each
    # time the VM is restarted. This is needed to ensure
    # the overlayFS is still properly mounted.
    systemd.mounts = (
      map (vm: {
        enable = true;
        where = "/var/lib/cirrusvm/${vm.name}/overlay/merged";
        type = "overlay";
        what = "overlay";
        options = "lowerdir=${cacheDir},upperdir=/var/lib/cirrusvm/${vm.name}/overlay/upper,workdir=/var/lib/cirrusvm/${vm.name}/overlay/work";
        partOf = [ "cirrus-${vm.name}.service" ];
        before = [ "cirrus-${vm.name}.service" ];
        wantedBy = [ "multi-user.target" ];
      }) vmList
    );

    systemd.services =
      builtins.trace
        (''
          Deploying:

          - ${toString cfg.vms.small.count}x small VMs: using ${
            toString (cfg.vms.small.count * cfg.vms.small.cpu)
          } threads & ${toString (cfg.vms.small.count * cfg.vms.small.memory)} GB
          - ${toString cfg.vms.medium.count}x medium VMs: using ${
            toString (cfg.vms.medium.count * cfg.vms.medium.cpu)
          } threads & ${toString (cfg.vms.medium.count * cfg.vms.medium.memory)} GB
          TOTAL: ${
            toString (cfg.vms.small.count * cfg.vms.small.cpu + cfg.vms.medium.count * cfg.vms.medium.cpu)
          } threads & ${
            toString (cfg.vms.small.count * cfg.vms.small.memory + cfg.vms.medium.count * cfg.vms.medium.memory)
          } GB
        '')
        (
          builtins.listToAttrs (
            map (vm: {
              name = "cirrus-${vm.name}";
              value = {
                after = [ "var-lib-cirrusvm-${vm.name}-overlay-merged.mount" ];
                requires = [ "var-lib-cirrusvm-${vm.name}-overlay-merged.mount" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  Restart = "always";
                  User = "cirrus-vm";
                  Group = "cirrus-vm";
                  WorkingDirectory = "/var/lib/cirrusvm/${vm.name}/";
                  ExecStart = "${pkgs.writeShellScript "start-vm-${vm.name}.sh" ''
                    set -o xtrace

                    # TODO: this should be clean?
                    echo "STEP start-pre-cleaning-up-upper for ${vm.name}"
                    SOURCE="/var/lib/cirrusvm/${vm.name}/overlay/upper"
                    if [ -d "$SOURCE" ]; then
                      echo "cleaning up files in $SOURCE"
                      rm -rf --verbose $SOURCE/*
                      echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
                    fi

                    echo "STEP start-pre-cleaning-up-disk-images for ${vm.name}"
                    rm *.qcow2 || true

                    echo "STEP copy-cirrus-worker-config for ${vm.name}"
                    SOURCE="/etc/cirrus/worker.yml"
                    DEST="/var/lib/cirrusvm/${vm.name}/config/"
                    if [ -f "$SOURCE" ]; then
                      echo "cleaning up files in $SOURCE"
                      cp $SOURCE $DEST --verbose
                    else
                      echo "worker config not found: $SOURCE"
                      exit 1
                    fi

                    echo "STEP set-cache-permissions-pre-start for ${vm.name}"
                    chown cirrus-vm:cirrus-vm -R ${cacheDir}/*
                    chmod 700 -R ${cacheDir}/*

                    echo "STEP start-vm for ${vm.name}"
                    ${
                      (lib.nixosSystem {
                        system = "x86_64-linux";
                        modules = [
                          (mkQemu {
                            id = vm.id;
                            name = vm.name;
                            size = vm.size;
                            runner_name = cfg.name;
                            memory = cfg.vms."${vm.size}".memory;
                            cpu = cfg.vms."${vm.size}".cpu;
                          })
                        ];
                      }).config.system.build.vm
                    }/bin/run-${vm.name}-vm

                    UPPER="/var/lib/cirrusvm/${vm.name}/overlay/upper"

                    echo "STEP copy-new-ccache-entries for ${vm.name}"
                    SOURCE="$UPPER/ccache"
                    DEST="${cacheDir}/ccache"
                    if [ -d "$SOURCE" ]; then
                      echo "removing lock and stats files from $SOURCE"
                      rm -rf $SOURCE/lock
                      rm -rf $SOURCE/*/stats
                      rm -rf $SOURCE/*/*/stats
                      echo "copying non-existing ccache files from $SOURCE to $DEST"
                      cp -n -R $SOURCE/* $DEST/ --verbose
                    fi

                    echo "STEP copy-new-built-depends for ${vm.name}"
                    SOURCE="$UPPER/depends/built"
                    DEST="${cacheDir}/depends/built"
                    if [ -d "$SOURCE" ]; then
                      echo "copying newly built depends from $SOURCE to $DEST"
                      cp -n -R $SOURCE/* $DEST/ --verbose
                    fi

                    echo "STEP copy-new-depends-sources for ${vm.name}"
                    SOURCE="$UPPER/depends/sources/"
                    DEST="${cacheDir}/depends/sources/"
                    if [ -d "$SOURCE" ]; then
                      echo "copying new depends sources from $SOURCE to $DEST"
                      cp -n -R $SOURCE/* $DEST/ --verbose
                    fi

                    echo "STEP copy-new-prev_releases for ${vm.name}"
                    SOURCE="$UPPER/prev_releases/"
                    DEST="${cacheDir}/prev_releases/"
                    if [ -d "$SOURCE" ]; then
                      echo "copying new prev_releases files from $SOURCE to $DEST"
                      cp -n -R $SOURCE/* $DEST/ --verbose
                    fi

                    echo "STEP move-docker-ci-image-cache for ${vm.name}"
                    SOURCE="$UPPER/docker/ci-imgs"
                    DEST="${cacheDir}/docker/ci-imgs"
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

                    echo "STEP copy-docker-base-images for ${vm.name}"
                    SOURCE="$UPPER/docker/base-imgs"
                    DEST="${cacheDir}/docker/base-imgs"
                    if [ -d "$SOURCE" ]; then
                      echo "copying new docker base-imgs from $SOURCE to $DEST"
                      cp -n -R $SOURCE/* $DEST/ --verbose
                    fi

                    echo "STEP set-cache-permissions-after-copy for ${vm.name}"
                    chown cirrus-vm:cirrus-vm -R ${cacheDir}/*
                    chmod 700 -R ${cacheDir}/*

                    echo "STEP cleaning-up-cache for ${vm.name}"
                    SOURCE="$UPPER"
                    if [ -d "$SOURCE" ]; then
                      echo "cleaning up files in $SOURCE"
                      rm -rf $SOURCE/*
                      echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
                    fi
                  ''}";
                };
              };
            }) vmList
          )
        );

    users.users."cirrus-vm" = {
      isNormalUser = true;
      createHome = false;
      group = "cirrus-vm";
      uid = 8333; # TODO: document
    };
    users.groups."cirrus-vm" = { };

    systemd.tmpfiles.settings = (
      builtins.listToAttrs (
        map (vm: {
          name = "${vm.name}";
          value = {
            "/var/lib/cirrusvm/${vm.name}/" = {
              d = {
                user = "cirrus-vm";
                group = "cirrus-vm";
                mode = "0700";
              };
            };
            "/var/lib/cirrusvm/${vm.name}/overlay" = {
              d = {
                user = "cirrus-vm";
                group = "cirrus-vm";
                mode = "0700";
              };
            };
            "/var/lib/cirrusvm/${vm.name}/config" = {
              d = {
                user = "cirrus-vm";
                group = "cirrus-vm";
                mode = "0700";
              };
            };
            "/var/lib/cirrusvm/${vm.name}/overlay/upper/" = {
              d = {
                user = "cirrus-vm";
                group = "cirrus-vm";
                mode = "0700";
              };
            };
            "/var/lib/cirrusvm/${vm.name}/overlay/merged/" = {
              d = {
                user = "cirrus-vm";
                group = "cirrus-vm";
                mode = "0700";
              };
            };
            "/var/lib/cirrusvm/${vm.name}/overlay/work/" = {
              d = {
                user = "cirrus-vm";
                group = "cirrus-vm";
                mode = "0700";
              };
            };
          };
        }) vmList
      )
    );

    systemd.tmpfiles.rules = [
      "d '/var/lib/cirrusvm'                    700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}'                          700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/depends'                  700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/depends/built'            700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/depends/sources'          700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/ccache'                   700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/prev_releases'            700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/docker'                   700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/docker/base-imgs'         700 'cirrus-vm' 'cirrus-vm' - -"
      "d '${cacheDir}/docker/ci-imgs'           700 'cirrus-vm' 'cirrus-vm' - -"
      "f '${cacheDir}/.this-file-should-exist'  700 'cirrus-vm' 'cirrus-vm' - -"
      # set 700 on all existing assets
      "Z '${cacheDir}/*'                        700 'cirrus-vm  'cirrus-vm' - -"
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
