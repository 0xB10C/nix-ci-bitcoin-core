{
  config,
  modulesPath,
  lib,
  pkgs,
  microvm,
  ...
}:

let
  mkVM = (import ../vm/vm.nix { inherit pkgs config microvm; });

  vms = [
    { id = 1; size = "small"; }
    { id = 2; size = "small"; }
    { id = 3; size = "small"; }
  ];

  # builds an ssh config file for the VMs
  # allowing easy ssh access to debug the VMs
  sshConfig = lib.concatStrings (map (vm:
    let
      name = "vm${toString vm.id}";
    in    
    ''
      Host ${name}
        HostName 127.0.0.1
        Port ${toString (2000 + vm.id)}
        User root
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    ''
  ) vms);

  # defines a list of overlay mounts for the VMs
  # These overlays are 'partOf' the microVM service
  # for each VM and are restarted (and re-created) each
  # time the VM is restarted. This is needed to ensure
  # the overlayFS is still properly mounted.
  overlayMounts = (map (vm:
    let
      name = "vm${toString vm.id}";
    in    
      {
        enable = true;
        where = "/data/overlay/${name}/merged";
        type = "overlay";
        what = "overlay";
        options = "lowerdir=/data/ci-persist,upperdir=/data/overlay/${name}/upper,workdir=/data/overlay/${name}/work";
        partOf = [ "microvm@${name}.service" ];
        before = [ "microvm@${name}.service" ];
        wantedBy = [ "multi-user.target" ];
      }
  ) vms);

  vmNodeExporterScrapeConfigs = (map (vm:
    let
      name = "vm${toString vm.id}";
    in    
      {
        job_name = name;
          static_configs = [
          { targets = [ "127.0.0.1:${toString (9500+vm.id)}" ]; }
        ];
      }
  ) vms);

  mkVMs = vm: 
    let
      name = "vm${toString vm.id}";
    in {
      # define the actual microvm 
      microvm.vms.${name} = mkVM vm.id name vm.size;

      systemd.services."microvm@${name}" = {
        after = [ "data-overlay-${name}-merged.mount" ];
        requires = [ "data-overlay-${name}-merged.mount" ];
        serviceConfig = {
          # before the VM starts, remove all disk images
          ExecStartPre = [
            "${pkgs.bash}/bin/bash -c 'rm /var/lib/microvms/${name}/*.img || true'"
          ];

          # after the VM stops, copy cache data and clean up
          ExecStopPost = [
            "${pkgs.writeShellScript "copy-new-ccache-entries.sh" ''
              echo "running 01 copy-new-ccache-entries.sh for ${name}"
              SOURCE="/data/vm-cache/${name}/ccache"
              DEST="/data/ci-persist/ccache"
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
              echo "running 02 copy-new-built-depends.sh for ${name}"
              SOURCE="/data/vm-cache/${name}/depends/built"
              DEST="/data/ci-persist/depends/built"
              if [ -d "$SOURCE" ]; then
                echo "copying newly built depends from $SOURCE to $DEST"
                cp -n -R $SOURCE/* $DEST/ --verbose
              fi
            ''}"
            "${pkgs.writeShellScript "copy-new-depends-sources.sh" ''
              echo "running 03 copy-new-depends-sources.sh for ${name}"
              SOURCE="/data/vm-cache/${name}/depends/sources/"
              DEST="/data/ci-persist/depends/sources/*"
              if [ -d "$SOURCE" ]; then
                echo "copying new depends sources from $SOURCE to $DEST"
                cp -n -R $SOURCE/* $DEST/ --verbose
              fi
            ''}"
            "${pkgs.writeShellScript "copy-new-prev_releases.sh" ''
              echo "running 04 copy-new-prev_releases.sh for ${name}"
              SOURCE="/data/vm-cache/${name}/prev_releases/*"
              DEST="/data/ci-persist/prev_releases/"
              if [ -d "$SOURCE" ]; then
                echo "copying new prev_releases files from $SOURCE to $DEST"
                cp -n -R $SOURCE/* $DEST/ --verbose
              fi
            ''}"
            "${pkgs.writeShellScript "move-docker-image-cache.sh" ''
              echo "running 05 move-docker-image-cache.sh for ${name}"
              set -o xtrace
              SOURCE="/data/vm-cache/${name}/docker"
              DEST="/data/ci-persist/docker/"
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
              echo "running 06 cleaning-up-cache.sh for ${name}"
              SOURCE="/data/vm-cache/${name}"            
              if [ -d "$SOURCE" ]; then            
                echo "cleaning up files in $SOURCE"
                rm -rf $SOURCE/*
                echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
              fi
            ''}"
          ];
        };
      };

      systemd.services."bindfs-mount-upper-${name}" = {
        description = "bindfs mount owned by microvm for the ${name}'s /cache dir";
        after = [ "local-fs.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStartPre = [
            "${pkgs.writeShellScript "create-${name}-cache-dir.sh" ''
              echo "creating vm-cache dir for ${name}"
              mkdir -p /data/vm-cache/${name}
              chown microvm:kvm /data/vm-cache/${name} -R
              chmod 700 /data/vm-cache/${name} -R
            ''}"
          ];
          ExecStart = "${pkgs.bindfs}/bin/bindfs --force-user=microvm /data/overlay/${name}/upper/ /data/vm-cache/${name}";
          ExecStop = "umount /data/vm-cache/${name}";
          RemainAfterExit = true;
        };
      };

      systemd.mounts = overlayMounts;

      systemd.tmpfiles.settings = {
        "${name}" = {
          "/data/vm-cache/${name}/" = {
            d = {
              user = "microvm";
              group = "kvm";
              mode = "0700";
            };
          };
          "/data/overlay/${name}/upper/" = {
            d = {
              user = "root";
              group = "root";
              mode = "0700";
            };
          };
          "/data/overlay/${name}/work" = {
            d = {
              user = "root";
              group = "root";
              mode = "0700";
            };
          };
        };
      };

    };

  vmConfigurations = lib.foldl' lib.recursiveUpdate {} (map mkVMs vms);  
in
  vmConfigurations //
  {
  imports = [
    # microvm.host
    ./ci-persist.nix
    ./monitoring.nix
  ];
  services.openssh.enable = true;

  environment.systemPackages = [
    pkgs.ccache
    pkgs.htop
    pkgs.vim
    pkgs.tree
  ];

  programs.ssh.extraConfig = sshConfig;

  users.users.root.openssh.authorizedKeys.keys = [
    # b10c
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtQmhXAp3F/KcaK3NzA30b2jE26zdYg6msXTXMBVJvZ8p8adHVYrl1QVFieeIjZvy1sj0gMXPOjYpgOm7OdwiZL4h0B9/FU49h+TLly6+YBwO/XYDR84WCvtv1/HVrVSIcYdMZo2+5fnGV3zxrtC/ndBheu17PbW7pvB+O7ODjxJa2tu66Q0If1cYH85PNkF3/jzsjQRwzo88eMxPEqVfp3MfYxJR53oWlXN2SUe1F/6FkeUulx9FpHgmWtPVLsGLd285GeQwsBUIRl+VnJQwCSB69YWgATR0zlRloFcfu1DhOCo5rGXnOvGmOWZ9LYpybwvuotQ8AGbsdNpZWYhQUNGF/YealVkyKABKhIHRQcGkqqqSGHpx6ui1tLkBHJWFgdCTU6eaK9OhgnjyHDJDtPGDl/Ek84JGYHp8+seHvE0/4GvQ2hQXUEUSQpxNwlwT1TKJ8uEMQuSn5zOK9TBSrYktW9h7HRe0ZQd23C6J38Lhxt9bJ3FcyfxFqogJZz3szAo0iR/bsjyeErfjKqeDHDZu4x9OISntrL42tCtNnb9ucWHo2nd+y+2X/hGQlGDdCo+RFi4cZeIHusibmr6J8FHnYgtNldamU2MYKk9R26MmPwVD/eM1Eq/sKL1jhAH3vfnxSifsQ6DvMicRiXWy/AOb3ZdZWVCLSd0mmrjkncQ=="
    # willcl-ark
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
  ];

  nix.settings = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  services.prometheus.scrapeConfigs = vmNodeExporterScrapeConfigs;

  system.stateVersion = "24.05";
}
