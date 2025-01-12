{
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

  # build the graph of `buildCrate`s for a single `cargo build`-equivalent
  # invocation.
  buildGraph = self.callPackage ./buildGraph.nix {};

  # the high-level interface to build rust packages.
  buildPackage = self.callPackage ./buildPackage.nix {};

  # The Rust binary used to generate the `Cargo.metadata.json` file.
  nargo-metadata = self.callPackage ./nargo-metadata.nix {};

  # A Rust binary used for testing feature resolution.
  nargo-resolve = self.callPackage ./nargo-resolve.nix {};

  # A Rust binary wrapping around `rustc`, used during crate builds.
  nargo-rustc = self.callPackage ./nargo-rustc.nix {};

  # # crane `vendorCargoDeps` on this repo.
  # nargoVendoredCargoDeps = craneLib.vendorCargoDeps {src = ../.;};

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
})
