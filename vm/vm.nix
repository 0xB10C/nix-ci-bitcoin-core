{ pkgs, config, microvm,  ... }:

{
  id,
  name,
  size,
  runner_name,
  memory,
  cpu,
}: {

  autostart = true;
  restartIfChanged = true;

  config = {
    imports = [ ./cirrus-runner.nix ];

    _module.args = {
      inherit id name size runner_name;
    };

    microvm = {
      hypervisor = "qemu";
      mem = (memory * 1024);
      vcpu = cpu;
      shares = [
        {
          # It is highly recommended to share the host's nix-store
          # with the VMs to prevent building huge images.
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
          securityModel = "mapped";
        }
        {
          source = "/etc/cirrus/";
          mountPoint = "/etc/cirrus";
          tag = "etc-cirrus";
          proto = "virtiofs";
          securityModel = "mapped";
        }
        {
          source = "/data/overlay/${name}/merged";
          mountPoint = "/persist";
          tag = "persist";
          proto = "virtiofs";
          securityModel = "mapped";
        }
      ];
      volumes = [
        {
          # this is an ext4 volume, but we repurpose it as swap using a systemd
          # service
          mountPoint = "/swap";
          image = "swap.img";
          label = "swap";
          size = 16 * 1024;
        }
      ];
      forwardPorts = [
        # forward host port 2001, 2002, .. -> 22, to ssh into the VM
        {
          from = "host";
          host.port = (2000 + id);
          guest.port = 22;
        }
        # forward host port 9501, 9502, .. -> 9200, to scrape prometheus node metrics from the VM
        {
          from = "host";
          host.port = (9500 + id);
          guest.port = 9002;
        }
      ];
      interfaces = [
        {
          type = "user";
          id = "vm-${toString id}";
          mac = "02:00:00:00:00:0${toString id}";
        }
      ];
    };

    systemd.services.make-swap-on-volume = {
      description = "repurpose /swap (ext4) as swap";
      wantedBy = [ "multi-user.target" ];
      script = ''
        ${pkgs.busybox}/bin/umount /dev/disk/by-label/swap
        ${pkgs.busybox}/bin/mkswap /dev/disk/by-label/swap -L swap
        ${pkgs.busybox}/bin/swapon LABEL=swap
        echo "swap on LABEL=swap $(free -h)"
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };

    fileSystems."/" = {
      device = "rootfs";
      fsType = "tmpfs";
      options = [ "size=20G,mode=0755" ];
      neededForBoot = true;
    };

    # TODO: disable root login..
    users.users.root.password = "toor";
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "yes";
      settings.PasswordAuthentication = true;
    };

    services.cirrus-runner = {
      enable = true;
      name = "${runner_name}-${name}";
      size = size;
    };

    virtualisation.docker = {
      rootless = {
        enable = true;
        setSocketVariable = true;
        daemon.settings = {
          dns = [ "8.8.8.8" "1.1.1.1" ];
          features = {
            containerd-snapshotter = true;
          };
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      config.services.prometheus.exporters.node.port
    ];

    services.prometheus = {
      exporters = {
        node = {
          enable = true;
          enabledCollectors = [ "systemd" ];
          port = 9002;
        };
      };
    };

    system.stateVersion = "24.05";
  };
}
