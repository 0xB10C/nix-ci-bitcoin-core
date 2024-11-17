{ pkgs, ... }:

let
  ccacheDir = "/data/ci-data/nginx-ccache/";
in
{
  systemd.tmpfiles.rules = [ "d '${ccacheDir}' 0770 'nginx' 'nginx' - -" ];
  systemd.services.nginx.serviceConfig.ReadWriteDirectories = "${ccacheDir}";

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

}
