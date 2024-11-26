{ pkgs, config, microvm,  ... }:

id: name: size: {

  autostart = true;
  restartIfChanged = true;

  config = {
    imports = [ ./cirrus-runner.nix ];

    _module.args = {
      inherit id name size; 
    };

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
          mountPoint = "/var";
          image = "var.img";
          size = 15 * 1024;
        }
        {
          mountPoint = "/ci_container_base";
          image = "ci.img";
          size = 20 * 1024;
        }
      ];
      forwardPorts = [
        # forward local port 2001, 2002, .. -> 22, to ssh into the VM
        {
          from = "host";
          host.port = (2000 + id);
          guest.port = 22;
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
      name = name;
      configFile = "/etc/cirrus/worker.yml";
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

    system.stateVersion = "24.05";
  };
}
