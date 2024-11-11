{
  config,
  modulesPath,
  lib,
  pkgs,
  name,
  arch,
  type,
  ...
}:
let
  CIRRUS_WORKER_HOME = "/var/lib/cirrus-worker";
  secretsFile = ./sops/${name}.yaml;
  secretsProvisioned = builtins.pathExists secretsFile;
in
{
  assertions = [
    {
      assertion = !(type == "arm64" && arch != "aarch64-linux");
      message = "can't use a type=${type} on a ${arch} host";
    }
  ];

  virtualisation.podman.enable = true;

  # Configure docker in rootless mode to run the CI scripts
  virtualisation.docker = {
    enable = true;
    rootless = {
      enable = true;
      setSocketVariable = true;
    };
    daemon.settings = {
      data-root = "/docker/data-root";
    };
  };

  sops.secrets =
    if secretsProvisioned then
      {
        "cirrus.env" = {
          mode = "0400";
          owner = config.users.users.cirrus-worker.name;
          group = config.users.groups.cirrus-worker.name;
          path = "${CIRRUS_WORKER_HOME}/cirrus.env";
          restartUnits = [ "cirrus-worker.service" ];
        };
        "ccache.conf" = {
          mode = "0400";
          owner = config.users.users.cirrus-worker.name;
          group = config.users.groups.cirrus-worker.name;
          path = "/etc/ccache.conf";
          restartUnits = [ "cirrus-worker.service" ];
        };
      }
    else
      { };

  systemd.services.cirrus-worker = {
    description = "Cirrus CI Worker";
    after = [
      "network.target"
      "docker.service"
    ];
    wants = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.cirrus-cli}/bin/cirrus worker run --name ${name} --token $CIRRUS_TOKEN --labels type=${type}";
      Restart = "always";
      User = config.users.users.cirrus-worker.name;
      EnvironmentFile = "${CIRRUS_WORKER_HOME}/cirrus.env";
    };
    environment = {
      XDG_CACHE_HOME = "${CIRRUS_WORKER_HOME}/.cache";
      PATH = lib.mkForce (
        lib.makeBinPath [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.systemd
          pkgs.cirrus-cli
          pkgs.docker
          pkgs.python3
          pkgs.git
          pkgs.podman
        ]
      );
      DOCKER_HOST = "unix:///var/run/docker.sock";
      RESTART_CI_DOCKER_BEFORE_RUN = "1";
      CCACHE_CONFIGPATH = "/etc/ccache.conf";
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts."127.0.0.1:8000" = {
      listen = [{ addr = "127.0.0.1"; port = 8000; }];
      locations."/" = {
        proxyPass = "https://test-ccache-bitcoin-core-ci.b10c.me/";
      };
    };
  };

  users.users.cirrus-worker = {
    isSystemUser = true;
    group = "cirrus-worker";
    description = "Cirrus CI worker user";
    home = CIRRUS_WORKER_HOME;
    createHome = true;
    shell = pkgs.bash;
    extraGroups = [ "docker" ];
  };
  users.groups.cirrus-worker = { };

  # Create CIRRUS_WORKER_HOME/.cache
  system.activationScripts = {
    cirrusWorkerDir = ''
      mkdir -p ${CIRRUS_WORKER_HOME}/.cache
      chown cirrus-worker:cirrus-worker ${CIRRUS_WORKER_HOME}/.cache
      chmod 700 ${CIRRUS_WORKER_HOME}/.cache
    '';
  };
}
