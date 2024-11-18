{ pkgs, microvm, ... }:

id: {
  config = {
    imports = [ ./cirrus-runner.nix ];

    microvm = {
      hypervisor = "qemu";
      mem = 8192;
      vcpu = 2;
      shares = [
        {
          # It is highly recommended to share the host's nix-store
          # with the VMs to prevent building huge images.
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
        {
          source = "/etc/cirrus/";
          mountPoint = "/etc/cirrus";
          tag = "etc-cirrus";
          proto = "virtiofs";
        }
        {
          source = "/data/ci-persist/";
          mountPoint = "/persist";
          tag = "persist";
          proto = "virtiofs";
        }
      ];
      volumes = [
        {
          mountPoint = "/var";
          image = "var.img";
          size = 40 * 1024;
        }
        {
          mountPoint = "/ci_container_base";
          image = "ci.img";
          size = 15 * 1024;
        }
      ];
      forwardPorts = [
        # forward local port 2001, 2002, .. -> 22, to ssh into the VM
        {
          from = "host";
          host.port = (2000 + id);
          guest.port = 22;
        }

        # forward port 8000 with a nginx with ccache to the VM
        {
          from = "guest";
          guest.address = "10.0.2.10";
          guest.port = 8000;
          host.address = "127.0.0.1";
          host.port = 8000;
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

    # TODO: disable root login..
    users.users.root.password = "toor";
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "yes";
      settings.PasswordAuthentication = true;
    };

    services.cirrus-runner = {
      enable = true;
      name = "vm${toString id}";
      configFile = "/etc/cirrus/worker.yml";
    };

    # Configure docker in rootless mode to run the CI scripts
    virtualisation.docker = {
      enable = true;
      rootless = {
        enable = true;
        setSocketVariable = true;
      };
    };

    system.stateVersion = "24.05";

  };
}
