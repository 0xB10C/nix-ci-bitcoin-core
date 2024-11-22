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

  mkVMs = vm: 
    let
      name = "vm${toString vm.id}";
    in {
      # define the actual microvm 
      microvm.vms.${name} = mkVM vm.id name vm.size;

      systemd.services."microvm@${name}".serviceConfig = {
        ExecStartPre = [
          "${pkgs.bash}/bin/bash -c 'rm /var/lib/microvms/${name}/*.img || true'"
        ];
        ExecStopPost = [
          "${pkgs.writeShellScript "copy-new-ccache-entries.sh" ''
            echo "running 01 copy-new-ccache-entries.sh for ${name}"
            SOURCE="/data/vm-cache/${name}/ccache"
            DEST="/data/ci-persist/ccache"
            if [ -d "$SOURCE" ]; then
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
            SOURCE="/data/vm-cache/${name}/depends/sources"
            DEST="/data/ci-persist/depends/sources"
            if [ -d "$SOURCE" ]; then
              echo "copying new depends sources from $SOURCE to $DEST"
              cp -n -R $SOURCE/* $DEST/ --verbose
            fi
          ''}"
          "${pkgs.writeShellScript "copy-new-prev_releases.sh" ''
            echo "running 04 copy-new-prev_releases.sh for ${name}"
            SOURCE="/data/vm-cache/${name}/prev_releases"
            DEST="/data/ci-persist/prev_releases"
            if [ -d "$SOURCE" ]; then
              echo "copying new prev_releases files from $SOURCE to $DEST"
              cp -n -R $SOURCE/* $DEST/ --verbose
            fi
          ''}"
          "${pkgs.writeShellScript "cleaning-up-cache.sh" ''
            echo "running 05 cleaning-up-cache.sh for ${name}"
            SOURCE="/data/vm-cache/${name}"            
            if [ -d "$SOURCE" ]; then            
              echo "cleaning up files in $SOURCE"
              rm -rf $SOURCE/*
              echo "done cleaning up files in $SOURCE: $(ls $SOURCE)"
            fi
          ''}"
        ];
      };

      systemd.services."bindfs-mount-upper-${name}" = {
        description = "bindfs mount owned by microvm for the ${name}'s /cache dir";
        after = [ "local-fs.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStartPre = [
            "${pkgs.writeShellScript "create-vm-cache-dir.sh" ''
              echo "creating vm-cache dir for ${name}"
              mkdir -p /data/vm-cache/${name}
              chown microvm:root /data/vm-cache/${name} -R
              chmod 700 /data/vm-cache/${name} -R
            ''}"
          ];
          ExecStart = "${pkgs.bindfs}/bin/bindfs --force-user=microvm /data/overlay/upper/${name} /data/vm-cache/${name}";
          ExecStop = "umount /data/vm-cache/${name}";
          RemainAfterExit = true;
        };
      };

      systemd.tmpfiles.rules = [
        # "d '/data/vm-cache/${name}/'       0700 'microvm' 'root' - -"
        "d '/data/overlay/upper/${name}/'  0700 'root' 'root' - -"
        "d '/data/overlay/work/${name}/'   0700 'root' 'root' - -"
        "Z '/data/overlay/merged/${name}/' 0700 'root' 'root' - -"
      ];

      fileSystems."/data/overlay/merged/${name}" = {
        device = "none";
        fsType = "overlay";
        options = [
          "lowerdir=/data/ci-persist/"
          "upperdir=/data/overlay/upper/${name}"
          "workdir=/data/overlay/work/${name}"
        ];
      };      
    };

  vmConfigurations = lib.foldl' lib.recursiveUpdate {} (map mkVMs vms);  
in
  vmConfigurations //
  {
  imports = [
    # microvm.host
    ./ccache.nix
    ./ci-persist.nix
    ./docker-registry.nix
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
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  system.stateVersion = "24.05";
}
