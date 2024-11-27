# cargo build --bin nargo-resolve
{
  craneLib,
  lib,
  nargoVendoredCargoDeps,
}:
craneLib.buildPackage {
  pname = "nargo-resolve";
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
      ../crates/nargo-resolve
      ../crates/nargo-rustc/Cargo.toml
      ../crates/nargo-rustc/src/lib.rs
    ];
  };

  cargoExtraArgs = "-p nargo-resolve --bin nargo-resolve";

  cargoArtifacts = null;
  doCheck = false;
  doInstallCargoArtifacts = false;
  strictDeps = true;
}
