{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.microvm = {
    url = "github:astro/microvm.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, disko, microvm, ... }:

    let
      x86_64 = "x86_64-linux";
      mkDedicated =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            microvm.nixosModules.host
            ./host/host.nix
            ./disk-config-dual-nvme.nix
            ./dedicated-hardware-configuration.nix
            {
              networking.hostName = name;
            }
          ];
        };
      mkDev =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            microvm.nixosModules.host
            ./host/host.nix
            ./disk-config-single-nvme.nix
            ./hardware-configuration-dev.nix
            {
              networking.hostName = name;
              boot.loader.grub.devices = [
                "/dev/nvme0n1"
              ];
              boot.loader.grub.enable = true;
              boot.loader.grub.efiSupport = true;
              boot.loader.grub.efiInstallAsRemovable = true;
            }
          ];
        };
      mkBig =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            microvm.nixosModules.host
            ./host/host.nix
            ./disk-config-single-disk.nix
            ./hardware-configuration-big.nix
            {
              networking.hostName = name;
              boot.loader.grub.devices = [
                "/dev/sda"
              ];
              boot.loader.grub.enable = true;
              boot.loader.grub.efiSupport = true;
              boot.loader.grub.efiInstallAsRemovable = true;
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
    };
}
