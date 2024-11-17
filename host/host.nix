{
  config,
  modulesPath,
  lib,
  pkgs,
  microvm,
  ...
}:

let
  ccacheDir = "/data/ci-data/nginx-ccache/";
  mkVM = (import ../vm/vm.nix { inherit pkgs microvm; });
in
{
  imports = [ ];
  services.openssh.enable = true;

  environment.systemPackages = [
    pkgs.ccache
    pkgs.htop
    pkgs.vim
  ];

  users.users.root.openssh.authorizedKeys.keys = [
    # b10c
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtQmhXAp3F/KcaK3NzA30b2jE26zdYg6msXTXMBVJvZ8p8adHVYrl1QVFieeIjZvy1sj0gMXPOjYpgOm7OdwiZL4h0B9/FU49h+TLly6+YBwO/XYDR84WCvtv1/HVrVSIcYdMZo2+5fnGV3zxrtC/ndBheu17PbW7pvB+O7ODjxJa2tu66Q0If1cYH85PNkF3/jzsjQRwzo88eMxPEqVfp3MfYxJR53oWlXN2SUe1F/6FkeUulx9FpHgmWtPVLsGLd285GeQwsBUIRl+VnJQwCSB69YWgATR0zlRloFcfu1DhOCo5rGXnOvGmOWZ9LYpybwvuotQ8AGbsdNpZWYhQUNGF/YealVkyKABKhIHRQcGkqqqSGHpx6ui1tLkBHJWFgdCTU6eaK9OhgnjyHDJDtPGDl/Ek84JGYHp8+seHvE0/4GvQ2hQXUEUSQpxNwlwT1TKJ8uEMQuSn5zOK9TBSrYktW9h7HRe0ZQd23C6J38Lhxt9bJ3FcyfxFqogJZz3szAo0iR/bsjyeErfjKqeDHDZu4x9OISntrL42tCtNnb9ucWHo2nd+y+2X/hGQlGDdCo+RFi4cZeIHusibmr6J8FHnYgtNldamU2MYKk9R26MmPwVD/eM1Eq/sKL1jhAH3vfnxSifsQ6DvMicRiXWy/AOb3ZdZWVCLSd0mmrjkncQ=="
    # willcl-ark
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
  ];

  nix.settings = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  microvm.vms = {
    vm1 = mkVM 1;
    vm2 = mkVM 2;
    vm3 = mkVM 3;
  };

  networking.firewall.interfaces.lo.allowedTCPPorts = [ 8000 ];

  services.nginx = {
    enable = true;
    virtualHosts."ccache" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8000;
        }
      ];
      locations."/cache/" = {
        # based on https://github.com/ccache/ccache/wiki/HTTP-storage#nginx
        extraConfig = ''
          # Where to store cache files (must exist with proper file permissions already):
          alias ${ccacheDir};

          # Don't log 404 Not Found replies as errors.
          log_not_found off;

          # Enable needed HTTP methods:
          dav_methods PUT DELETE;

          # Allow creating subdirectories:
          create_full_put_path on;

          # Allow individual cache entries to be up to 100 MiB:
          client_max_body_size 100M;
        '';
      };
    };
  };

  systemd.tmpfiles.rules = [ "d '${ccacheDir}' 0770 'nginx' 'nginx' - -" ];
  systemd.services.nginx.serviceConfig.ReadWriteDirectories = "${ccacheDir}";

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  system.stateVersion = "24.05";
}
