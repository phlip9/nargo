# cargo build --bin nargo-resolve
{
  craneLib,
  lib,
  nargoVendoredCargoDeps,
}:
craneLib.buildPackage {
  pname = "nargo-rustc";
  version = "0.1.0";

  cargoVendorDir = nargoVendoredCargoDeps;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../.cargo
      ../crates/nargo-core
      ../crates/nargo-metadata/Cargo.toml
      ../crates/nargo-metadata/src/lib.rs
      ../crates/nargo-resolve/Cargo.toml
      ../crates/nargo-resolve/src/lib.rs
      ../crates/nargo-rustc
    ];
  };

  cargoExtraArgs = "--bin=nargo-rustc";

  cargoArtifacts = null;
  doCheck = false;
  doInstallCargoArtifacts = false;
  strictDeps = true;
}
