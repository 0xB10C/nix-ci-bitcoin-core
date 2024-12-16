{
  pkgs,
  config,
  modulesPath,
  ...
}:

let
in
{
  id,
  name,
  size,
  runner_name,
  memory,
  cpu
}:
{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    ./cirrus-runner.nix
  ];

  virtualisation = {
    cores = cpu;
    graphics = false;
    # increase for more p9 file system performance
    msize = (512 * 1024);
    memorySize = (memory * 1024);
    #diskSize = (20 * 1024);
    # the nix store in the VM should not be writable
    writableStore = false;
    qemu.virtioKeyboard = false;
    sharedDirectories = {
      "etc-cirrus" = {
        source = "/var/lib/cirrusvm/${name}/config";
        target = "/etc/cirrus";
        securityModel = "mapped-xattr";
      };
      "cache" = {
        source = "/var/lib/cirrusvm/${name}/overlay/merged";
        target = "/cache";
        securityModel = "mapped-xattr";
      };
    };
    # use tmpfs as root fs
    diskImage = null;
    # for docker.. TODO: doc
    emptyDiskImages = [ (16 * 1024) ];
    fileSystems."/home/cirrus-worker/docker" = {
      autoFormat = true;
      device = "/dev/vda"; # TODO: doc this name is chosen by QEMU, not here
      fsType = "ext4";
      noCheck = true;
    };
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
  };

  networking.hostName = name;
  services.sshd.enable = true;

  # Automatically start into journalctl on tty after the machine
  # booted. This allows us to see the VMs log on the host in systemd.
  services.getty = {
    loginProgram = "${pkgs.systemd}/bin/journalctl";
    loginOptions = "--follow --lines 100";
    autologinUser = "journal-reader";
  };
  users.groups.journal-reader = { };
  users.users.journal-reader = {
    isSystemUser = true;
    group = "journal-reader";
  };

  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "test";
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
        dns = [
          "8.8.8.8"
          "1.1.1.1"
        ];
        data-root = "/home/cirrus-worker/docker/";
        features = {
          containerd-snapshotter = true;
        };
      };
    };
  };
  systemd.user.services.docker.environment.DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK = "false";

  services.prometheus = {
    exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9002;
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ config.services.prometheus.exporters.node.port ];

  system.stateVersion = "24.11";
}
