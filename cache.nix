{
  config,
  modulesPath,
  lib,
  pkgs,
  name,
  arch,
  ...
}:
let
  secretsFile = ./sops/${name}.yaml;
  secretsProvisioned = builtins.pathExists secretsFile;
  ccacheDir = "/var/lib/ccache";
in
{

  environment.etc = {
    ccache-write = {
      text = ''
        runner:$2y$05$eWuklQWcN/m/jVHA5nr5T.vu902EK0HhYnbkxAXRyaF8aoalLCn.2
      '';
      # todo: set owner and group
      mode = "444";
    };
  };
  
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "ci-test-acme@b10c.me";

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  services.nginx = {
    enable = true;
    virtualHosts."test-ccache-bitcoin-core-ci.b10c.me" = {
      enableACME = true;
      forceSSL = true;
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

          # Allow all to read:
          dav_access user:rw group:rw all:r;

          # Allow specific users to write:
          limit_except GET HEAD {
            auth_basic "Ccache remote storage";
            auth_basic_user_file /etc/ccache-write;
          }
        '';
      };
    };
  };

  system.activationScripts = {
    ccacheDir = ''
      mkdir -p ${ccacheDir}
      chown nginx:nginx ${ccacheDir}
      chmod 700 ${ccacheDir}
    '';
  };
}
