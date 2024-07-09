# This derivation builds the `nargo-metadata` binary, which we use to generate
# the `Cargo.metadata.json` file in a cargo workspace.
#
# Currently this uses the nixpkgs `rustPlatform.buildRustPackage` builder, but
# we'll want to switch over to our own builder when that exists.
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "nargo-metadata";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../.cargo
      ../crates/nargo-metadata
    ];
  };

  cargoHash = "sha256-mPqCm6gP40+2qPatge+HFJf+TGCf/PpMbRpPW1TrP4U=";

  cargoBuildFlags = ["--bin=nargo-metadata"];

  doCheck = false;

  meta = {
    license = lib.licenses.mit;
    mainProgram = "nargo-metadata";
  };
}
