{
  craneLib,
  lib,
  pkgs,
}:
# Make an extension of the nixpkgs `callPackage` fn that also includes our own
# attrs below.
#
# See: [`nixpkgs#lib.makeScope`]
lib.makeScope pkgs.newScope (self: {
  # compile a single crate target with `nargo-rustc`, which wraps `rustc`
  buildCrate = self.callPackage ./buildCrate.nix {};

  # build graph of `buildCrate`s for a single `cargo build`-equivalent invocation.
  buildGraph = self.callPackage ./buildGraph.nix {};

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

  # Generate a `Cargo.build-plan.nix`.
  generateCargoBuildPlan = self.callPackage ./generateCargoBuildPlan.nix {};

  # Minimal `pkgs.mkShellNoCC` for `nix develop`
  mkMinShell = import ./mkMinShell.nix {pkgs = pkgs;};

  # The Rust binary used to generate the `Cargo.metadata.json` file.
  nargo-metadata = self.callPackage ./nargo-metadata.nix {};

  # A Rust binary used for testing feature resolution.
  nargo-resolve = self.callPackage ./nargo-resolve.nix {};

  # A Rust binary wrapping around `rustc`, used during crate builds.
  nargo-rustc = self.callPackage ./nargo-rustc.nix {};

  # crane `vendorCargoDeps` on this repo.
  nargoVendoredCargoDeps = craneLib.vendorCargoDeps {src = ../.;};

  # `nixprof` for profiling `nix build`
  nixprof = pkgs.callPackage ./nixprof.nix {};

  # The cargo feature resolution algorithm, implemented in nix.
  resolve = import ./resolve.nix {
    inherit lib;
    targetCfg = self.targetCfg;
  };

  # Rust `cfg(...)` expression parser and evaluator.
  targetCfg = import ./targetCfg.nix {inherit lib;};

  # Vendor a single crates.io package from its Cargo.metadata.json definition.
  vendorCargoDep = pkg:
  # TODO(phlip9): first check that this is a crates.io package
    pkgs.fetchzip {
      # Matches `nargo_metadata::output::Package::prefetch_name()`
      name = "crate-${pkg.name}-${pkg.version}";
      # Matches `nargo_metadata::output::Package::prefetch_url()`
      url = "https://static.crates.io/crates/${pkg.name}/${pkg.version}/download";
      hash = pkg.hash;
      extension = "tar.gz";
    };

  # Vendor all crates.io packages from a Cargo.metadata.json
  vendorCargoDeps = cargoMetadataJson:
    builtins.mapAttrs (_pkgId: pkg: self.nargoVendorCargoDep pkg) cargoMetadataJson.packages;
})
