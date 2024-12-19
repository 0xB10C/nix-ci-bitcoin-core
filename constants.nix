{

  # These settings roughly follow systemd's "strict" security profile
  # from https://github.com/fort-nix/nix-bitcoin/blob/master/pkgs/lib.nix
  defaultHardening = {
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    MemoryDenyWriteExecute = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectClock = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    ProtectControlGroups = true;
    RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
    RestrictNamespaces = true;
    LockPersonality = true;
    IPAddressDeny = "any";
    PrivateUsers = true;
    RestrictSUIDSGID = true;
    RemoveIPC = true;
    RestrictRealtime = true;
    ProtectHostname = true;
    CapabilityBoundingSet = "";
    # @system-service whitelist and docker seccomp blacklist (except for "clone"
    # which is a core requirement for systemd services)
    # @system-service is defined in src/shared/seccomp-util.c (systemd source)
    SystemCallFilter = [
      "@system-service"
      "~add_key kcmp keyctl mbind move_pages name_to_handle_at personality process_vm_readv process_vm_writev request_key setns unshare userfaultfd"
    ];
    SystemCallArchitectures = "native";
  };

  DOCKER_RAW_DISK_LOCATION = name: "/var/lib/cirrusvm/${name}/tmp/docker.raw";

  CIRRUS_WORKER_WORKDIR = "/var/lib/cirrus-worker";

}
