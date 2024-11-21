{ pkgs, ... }:

let
  registryDir = "/data/ci-data/docker-registry/";
in
{

  services.dockerRegistry = {
    enable = true;
    storagePath = registryDir;
    enableGarbageCollect = true;
    enableDelete = true;
  };

}
