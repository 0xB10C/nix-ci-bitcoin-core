{ pkgs, ... }:

let
  persistDir = "/data/ci-persist";
in
{
  systemd.tmpfiles.rules = [ "d '${ci-persist}' 0700 'root' 'root' - -" ];
}
