{ pkgs, microvm, ... }:

id: {
      config = {
        imports = [
          ./cirrus-runner.nix
        ];

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
          ];
          volumes = [ {
            mountPoint = "/var";
            image = "var.img";
            size = 40 * 1024;
          } ];
          forwardPorts = [
            # forward local port 220, 221, .. -> 22, to ssh into the VM
            { from = "host"; host.port = (2220+id); guest.port = 22; }

            # forward local port 80 -> 10.0.2.15:80 in the VLAN
            { from = "guest";
              guest.address = "10.0.2.10"; guest.port = 80;
              host.address = "127.0.0.1"; host.port = 80;
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
