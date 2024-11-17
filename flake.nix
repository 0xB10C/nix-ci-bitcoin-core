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
            ./disk-config-ax52.nix
            ./dedicated-hardware-configuration.nix
            {
              networking.hostName = name; 
            }
          ];
        };

      pkgs = import nixpkgs { system = "x86_64-linux"; };
    in
    {
      nixosConfigurations = {
        dedicated = mkDedicated "dedicated" x86_64; 
      };
    };
}
