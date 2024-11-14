{
  stdenv,
  lib,
  pkgs,
  buildGoModule,
  fetchFromGitHub,
  ...
}:

buildGoModule rec {
  name = "vetu";
  version = "v0.9.0";

  src = pkgs.fetchFromGitHub {
    owner = "cirruslabs";
    repo = "vetu";
    rev = version;
    sha256 = "sha256-yzgi7eKJujooqxD05JnECyyeohARSMifTPq9YcWhNXg=";
  };

  checkFlags =
    let
      # skip test that errors with: mkdir /homeless-shelter: permission denied
      skippedTests = [ "TestExplicitlyPulled" ];
    in
    [ "-skip=^${builtins.concatStringsSep "$|^" skippedTests}$" ];

  vendorHash = "sha256-Hl+DcGjBK7y013RwuLDQKVLHFC3sbD7SRAJgrKvSj7I=";

  runVend = true;
}
