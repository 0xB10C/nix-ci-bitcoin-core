{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    { nixpkgs, disko, ... }:

    let
      x86_64 = "x86_64-linux";

      mkCloud =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            ./base.nix
            ./disk-config.nix
            ./cloud-hardware-configuration.nix
            {
              networking.hostName = name; 
            }
          ];
        };
      mkDedicated =
        name: arch:
        nixpkgs.lib.nixosSystem {
          system = arch;
          modules = [
            disko.nixosModules.disko
            ./base.nix
            ./disk-config-ax52.nix
            ./dedicated-hardware-configuration.nix
            {
              networking.hostName = name; 
            }
          ];
        };

      pkgs = import nixpkgs { system = "x86_64-linux"; };
      vetuPackage = pkgs.callPackage ./vetu.nix { };
    in
    {
      packages.x86_64-linux.vetu = vetuPackage;
      nixosConfigurations = {
        cloud = mkCloud "cloud" x86_64;
        dedicated = mkDedicated "dedicated" x86_64; 
      };
    };
}
