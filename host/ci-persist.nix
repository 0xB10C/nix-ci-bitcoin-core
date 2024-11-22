{ pkgs, ... }:

let
  persistDir = "/data/ci-persist";
in
{
  systemd.tmpfiles.rules = [ 
    "d '${persistDir}'               0700 'microvm' 'root' - -"
    "d '${persistDir}/depends'       0700 'microvm' 'root' - -"
    "d '${persistDir}/ccache'        0700 'microvm' 'root' - -"
    "d '${persistDir}/prev_releases' 0700 'microvm' 'root' - -"
  ];  
}
