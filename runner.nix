{
  config,
  modulesPath,
  lib,
  pkgs,
  ...
}:
let 
  cirrus-runner-container = name: type: address: {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "192.168.100.10";
    localAddress = address;
    # Runs container in ephemeral mode with the empty root filesystem at boot.
    ephemeral = true;
    
    extraFlags = [
      # With ephemeral = true; the container is running with a tmpfs
      # mounted as /. The default tmpfs size is 4GB, which isn't enough
      # to build some of the docker images
      "--tmpfs=/:size=8G"
      # required to run docker inside a NixOS container
      "--system-call-filter=bpf"
      "--system-call-filter=@keyring"
    ];

    bindMounts = {
      # read-only mount the cirrus token from the host to the container
      "/etc/cirrus/" = {
        mountPoint = "/etc/cirrus/";
        isReadOnly = true;
      };
      # read-write mount the shared ccache dir
      "/var/ccache" = {
        mountPoint = "/var/ccache";
        isReadOnly = false;
      };
    };
    
    config = { config, pkgs, lib, ... }: {

      imports = [ ./cirrus-runner.nix ];
      environment.systemPackages = [ pkgs.htop ];
      services.cirrus-runner = {
        enable = true;
        name = name;
        type = type;
        configFile = "/etc/cirrus/worker.yml";
        ccacheDir = "/var/ccache";
      };

      networking = {
        # Use systemd-resolved inside the container
        # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
        useHostResolvConf = lib.mkForce false;
      };
      services.resolved.enable = true;
      
      # Configure docker in rootless mode to run the CI scripts
      virtualisation.docker = {
        enable = true;
        rootless = {
          enable = true;
          setSocketVariable = true;
        };
        daemon.settings = {  
          # data-root = "/docker/data-root";
        };
      };

      system.stateVersion = "24.05";
    };
  };
in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
  ];
  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  services.openssh.enable = true;

  environment.systemPackages = map lib.lowPrio [
    pkgs.ccache
    pkgs.cirrus-cli
    pkgs.curl
    pkgs.gitMinimal
    pkgs.nebula
  ];

  # Use authorized keys supplied at runtime from the deployment command
  users.users.root.openssh.authorizedKeys.keys =
    let
      sshKey = builtins.getEnv "CI_WORKER_SSH_KEY";
    in
    if sshKey != ""
    then [ sshKey ]
    else [
      # b10c
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtQmhXAp3F/KcaK3NzA30b2jE26zdYg6msXTXMBVJvZ8p8adHVYrl1QVFieeIjZvy1sj0gMXPOjYpgOm7OdwiZL4h0B9/FU49h+TLly6+YBwO/XYDR84WCvtv1/HVrVSIcYdMZo2+5fnGV3zxrtC/ndBheu17PbW7pvB+O7ODjxJa2tu66Q0If1cYH85PNkF3/jzsjQRwzo88eMxPEqVfp3MfYxJR53oWlXN2SUe1F/6FkeUulx9FpHgmWtPVLsGLd285GeQwsBUIRl+VnJQwCSB69YWgATR0zlRloFcfu1DhOCo5rGXnOvGmOWZ9LYpybwvuotQ8AGbsdNpZWYhQUNGF/YealVkyKABKhIHRQcGkqqqSGHpx6ui1tLkBHJWFgdCTU6eaK9OhgnjyHDJDtPGDl/Ek84JGYHp8+seHvE0/4GvQ2hQXUEUSQpxNwlwT1TKJ8uEMQuSn5zOK9TBSrYktW9h7HRe0ZQd23C6J38Lhxt9bJ3FcyfxFqogJZz3szAo0iR/bsjyeErfjKqeDHDZu4x9OISntrL42tCtNnb9ucWHo2nd+y+2X/hGQlGDdCo+RFi4cZeIHusibmr6J8FHnYgtNldamU2MYKk9R26MmPwVD/eM1Eq/sKL1jhAH3vfnxSifsQ6DvMicRiXWy/AOb3ZdZWVCLSd0mmrjkncQ=="
      # willcl-ark
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
    ];

  containers = {
    runner01 = cirrus-runner-container "r01" "small" "192.168.100.11";
    runner02 = cirrus-runner-container "r02" "medium" "192.168.100.12";
  };

  networking.nat.enable = true;
  networking.nat.internalInterfaces = ["ve-runner+"];
  networking.nat.externalInterface = "enp1s0"; # must match the hosts interface
 
  systemd.tmpfiles.rules = [
    "d /var/ccache 0755 root root -"
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
  };
  
  system.stateVersion = "24.05";
}
