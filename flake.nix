{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    { nixpkgs, disko, ... }:

    let
      x86_64 = "x86_64-linux";
      mkDedicated =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            ./disk-config-dual-nvme.nix
            ./dedicated-hardware-configuration.nix
            ./module.nix
            ./base.nix
            {
              networking.hostName = name;
              services.cirrus-ephemeral-vm-runner = {
                enable = true;
                name = "big";
                vms = {
                  small = {
                    count = 1;
                    cpu = 4;
                    memory = 8;
                  };
                  medium = {
                    count = 1;
                    cpu = 8;
                    memory = 16;
                  };
                };
              };
            }
          ];
        };
      mkDev =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            ./disk-config-single-nvme.nix
            ./hardware-configuration-dev.nix
            ./module.nix
            ./base.nix
            {
              networking.hostName = name;
              boot.loader.grub.devices = [
                "/dev/nvme0n1"
              ];
              boot.loader.grub.enable = true;
              boot.loader.grub.efiSupport = true;
              boot.loader.grub.efiInstallAsRemovable = true;
              services.cirrus-ephemeral-vm-runner = {
                enable = true;
                name = "dev";
                vms = {
                  small = {
                    count = 1;
                    cpu = 6;
                    memory = 10;
                  };
                };
              };
            }
          ];
        };
      mkBig =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            ./disk-config-single-disk.nix
            ./hardware-configuration-big.nix
            ./module.nix
            ./base.nix
            {
              networking.hostName = name;
              boot.loader.grub.devices = [
                "/dev/sda"
              ];
              boot.loader.grub.enable = true;
              boot.loader.grub.efiSupport = true;
              boot.loader.grub.efiInstallAsRemovable = true;

              services.cirrus-ephemeral-vm-runner = {
                enable = true;
                name = "big";
                vms = {
                  small = {
                    count = 5;
                    cpu = 4;
                    memory = 8;
                  };
                  medium = {
                    count = 4;
                    cpu = 8;
                    memory = 16;
                  };
                };
              };
            }
          ];
        };
      pkgs = import nixpkgs { system = "x86_64-linux"; };
    in
    {
      nixosConfigurations = {
        dedicated = mkDedicated "dedicated" x86_64;
        dev = mkDev "dev" x86_64;
        big = mkBig "big" x86_64;
      };
      nixosModules.default = import ./module.nix;
    };
}
