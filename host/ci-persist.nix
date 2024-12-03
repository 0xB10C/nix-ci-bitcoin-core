{ pkgs, ... }:

let
  persistDir = "/data/ci-persist";
in
{
  systemd.tmpfiles.rules = [
    "d '${persistDir}'                 0700 'microvm' 'root' - -"
    "d '${persistDir}/depends'         0700 'microvm' 'root' - -"
    "d '${persistDir}/depends/built'   0700 'microvm' 'root' - -"
    "d '${persistDir}/depends/sources' 0700 'microvm' 'root' - -"
    "d '${persistDir}/ccache'          0700 'microvm' 'root' - -"
    "d '${persistDir}/prev_releases'   0700 'microvm' 'root' - -"
    "d '${persistDir}/docker'          0700 'microvm' 'root' - -"
    "d '${persistDir}/docker/ingest'   0700 'microvm' 'root' - -"
    "d '${persistDir}/docker/blobs'    0700 'microvm' 'root' - -"
  ];
}
