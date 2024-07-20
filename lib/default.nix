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

  # The Rust binary used to generate the `Cargo.metadata.json` file.
  nargo-metadata = self.callPackage ./nargo-metadata.nix {};

  # The cargo feature resolution algorithm, implemented in nix.
  resolve = import ./resolve.nix {
    inherit lib;
  };
})
