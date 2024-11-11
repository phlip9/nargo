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

  # crane `vendorCargoDeps` on this repo.
  nargoVendoredCargoDeps = craneLib.vendorCargoDeps {src = ../.;};

  # The cargo feature resolution algorithm, implemented in nix.
  resolve = import ./resolve.nix {
    inherit lib;
    targetCfg = self.targetCfg;
  };

  # `cargo build`, implemented in nix.
  build = import ./build.nix {
    inherit lib;
    resolve = self.resolve;
    targetCfg = self.targetCfg;
  };

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
