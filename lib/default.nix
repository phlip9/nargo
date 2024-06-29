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

  # Generate Cargo.metadata.json
  generateCargoMetadata = self.callPackage ./generateCargoMetadata.nix {};
})
