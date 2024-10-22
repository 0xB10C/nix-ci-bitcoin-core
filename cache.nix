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
in
{

}
