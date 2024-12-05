{ pkgs, config, microvm,  ... }:

let
  swapDiskSize = 16; # in GB
in
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
        # {
        #   # this is an ext4 volume, but we repurpose it as swap using a systemd
        #   # service
        #   mountPoint = "/swap";
        #   image = "swap.img";
        #   label = "swap";
        #   size = swapDiskSize * 1024;
        # }
        {
          mountPoint = "/home/cirrus-worker";
          image = "cirrus-worker-home.img";
          size = 20 * 1024;
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
          id = name;
          mac = "02:00:00:00:00:0${toString id}";
        }
      ];
    };

    # repurpose the /swap ext4 volume as swap
    # systemd.services.make-swap-on-volume = {
    #   description = "repurpose /swap (ext4) as swap";
    #   wantedBy = [ "multi-user.target" ];
    #   script = ''
    #     ${pkgs.busybox}/bin/umount /dev/disk/by-label/swap
    #     ${pkgs.busybox}/bin/mkswap /dev/disk/by-label/swap -L swap
    #     ${pkgs.busybox}/bin/swapon LABEL=swap
    #     echo "swap on LABEL=swap $(free -h)"
    #   '';
    #   serviceConfig = {
    #     Type = "oneshot";
    #   };
    # };

    # check that /persist isn't empty. If it is empty, this indicates a
    # problem with the overlay mount on the host. The VM needs to shutdown.
    systemd.services.ensure-persist-is-not-empty = {
      description = "Ensure /persist is not empty";
      wantedBy = [ "multi-user.target" ];
      script = ''
        FILE=/persist/.this-file-should-exist
        echo "checking for $FILE"
        if [ -f $FILE ]; then
          echo "File $FILE exists - /persist mount is OK"
        else
          echo "File $FILE does not exist: /persist mount is NOT OK: shutting down VM"
          shutdown now
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };

    # TODO: disable root login.
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
          data-root = "/home/cirrus-worker/docker";
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
