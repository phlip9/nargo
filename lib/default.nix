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
  # inject some external dependencies
  craneLib = craneLib;

  # Generate the `Cargo.metadata.json` file used to build packages from a cargo
  # workspace.
  generateCargoMetadata = self.callPackage ./generateCargoMetadata.nix {};

  # Generate a `Cargo.build-plan.nix`.
  generateCargoBuildPlan = self.callPackage ./generateCargoBuildPlan.nix {};

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

  # `cargo build`, implemented in nix.
  build = self.callPackage ./build.nix {};

  # compile a single crate target with `nargo-rustc`, which wraps `rustc`
  buildCrate = self.callPackage ./buildCrate.nix {};

  # Rust `cfg(...)` expression parser and evaluator.
  targetCfg = import ./targetCfg.nix {inherit lib;};

  # Vendor a single crates.io package from its Cargo.metadata.json definition.
  vendorCargoDep = pkg: let
    # Matches `nargo_metadata::output::Package::prefetch_name()`
    name = "crate-${pkg.name}-${pkg.version}";
    # Matches `nargo_metadata::output::Package::prefetch_url()`
    url = "https://static.crates.io/crates/${pkg.name}/${pkg.version}/download";
  in
    # TODO(phlip9): first check that this is a crates.io package
    pkgs.fetchzip {
      name = name;
      url = url;
      hash = pkg.hash;
      extension = "tar.gz";
    };

  # Vendor all crates.io packages from a Cargo.metadata.json
  vendorCargoDeps = cargoMetadataJson:
    builtins.mapAttrs (_pkgId: pkg: self.nargoVendorCargoDep pkg) cargoMetadataJson.packages;
})
