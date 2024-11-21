{ pkgs, ... }:

let
  persistDir = "/data/ci-persist";
in
{
  systemd.tmpfiles.rules = [ "d '${persistDir}' 0700 'root' 'root' - -" ];
}
