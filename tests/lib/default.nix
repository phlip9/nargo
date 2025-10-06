{
  craneLib,
  lib,
  nargoLib,
  pkgs,
}:
# `nargoTestLib`
#
# Make an extension of `nargoLib.callPackage` fn (which itself extends
# `nixpkgs.callPackage`) that adds dev-/test-only entries.
#
# See: [`nixpkgs#lib.makeScope`]
lib.makeScope nargoLib.newScope (self: {
  # inject some external dependencies
  craneLib = craneLib;

  # empty bare `derivation` for benchmarking
  emptyDrv = builtins.derivation {
    name = "empty";
    system = pkgs.buildPlatform.system;
    builder = "${pkgs.bash}/bin/bash";
    args = ["-c" "echo '' > $out"];
    preferLocalBuild = true;
    allowSubstitutes = false;
  };

  # empty `stdenv.mkDerivation` for benchmarking
  emptyDrvStdenv = pkgs.runCommandNoCC "empty" {} "touch $out";

  # Generate the `Cargo.metadata.json` file used to build packages from a cargo
  # workspace.
  generateCargoMetadata = self.callPackage ./generateCargoMetadata.nix {};

  # Generate a `Cargo.build-plan.raw.json`.
  generateCargoBuildPlan = self.callPackage ./generateCargoBuildPlan.nix {};

  # Minimal `pkgs.mkShellNoCC` for `nix develop`
  mkMinShell = import ./mkMinShell.nix {pkgs = pkgs;};

  # `nixprof` for profiling `nix build`
  nixprof = pkgs.callPackage ./nixprof.nix {};
})
