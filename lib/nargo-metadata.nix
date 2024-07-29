# This derivation builds the `nargo-metadata` binary, which we use to generate
# the `Cargo.metadata.json` file in a cargo workspace.
#
# Currently this uses the nixpkgs `rustPlatform.buildRustPackage` builder, but
# we'll want to switch over to our own builder when that exists.
{
  craneLib,
  generateCargoMetadata,
  lib,
  resolve,
  nargoVendoredCargoDeps,
}:
craneLib.buildPackage {
  pname = "nargo-metadata";
  version = "0.1.0";

  cargoVendorDir = nargoVendoredCargoDeps;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../.cargo
      ../crates/nargo-core
      ../crates/nargo-metadata
      ../crates/nargo-resolve/Cargo.toml
      ../crates/nargo-resolve/src/lib.rs
    ];
  };

  cargoExtraArgs = "--bin=nargo-metadata";

  cargoArtifacts = null;
  doCheck = false;
  doInstallCargoArtifacts = false;
  strictDeps = true;

  passthru = {
    metadata = generateCargoMetadata {
      name = "nargo-metadata";
      # TODO(phlip9): replace this
      src = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../Cargo.toml
          ../Cargo.lock
          ../.cargo
          ../crates/nargo-core/Cargo.toml
          ../crates/nargo-metadata/Cargo.toml
          ../crates/nargo-resolve/Cargo.toml
        ];
      };
      cargoVendorDir = nargoVendoredCargoDeps;
    };

    resolve = resolve.resolveFeatures {
      metadata = builtins.fromJSON (builtins.readFile ../Cargo.metadata.json);
      buildTarget = "x86_64-unknown-linux-gnu";
      hostTarget = "x86_64-unknown-linux-gnu";
    };
  };

  meta = {
    license = lib.licenses.mit;
    mainProgram = "nargo-metadata";
  };
}
