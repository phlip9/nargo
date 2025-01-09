# This derivation builds the `nargo-metadata` binary, which we use to generate
# the `Cargo.metadata.json` file in a cargo workspace.
#
# Currently this uses the nixpkgs `rustPlatform.buildRustPackage` builder, but
# we'll want to switch over to our own builder when that exists.
{
  craneLib,
  generateCargoBuildPlan,
  generateCargoMetadata,
  lib,
  resolve,
  buildGraph,
  nargoVendoredCargoDeps,
  pkgs,
}:
craneLib.buildPackage rec {
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
      ../crates/nargo-rustc/Cargo.toml
      ../crates/nargo-rustc/src/lib.rs
    ];
  };

  cargoExtraArgs = "-p nargo-metadata --bin nargo-metadata";

  cargoArtifacts = null;
  doCheck = false;
  doInstallCargoArtifacts = false;
  strictDeps = true;

  passthru = rec {
    build-plan = generateCargoBuildPlan {
      name = pname;
      src = src;
      cargoVendorDir = nargoVendoredCargoDeps;
      cargoExtraArgs = cargoExtraArgs;
      hostTarget = "x86_64-unknown-linux-gnu";
    };

    metadataDrv = generateCargoMetadata {
      name = pname;
      src = src;
      cargoVendorDir = nargoVendoredCargoDeps;
    };

    metadata = builtins.fromJSON (builtins.readFile ../Cargo.metadata.json);

    resolved = resolve.resolveFeatures {
      metadata = metadata;
      buildTarget = "x86_64-unknown-linux-gnu";
      hostTarget = "x86_64-unknown-linux-gnu";
    };

    buildGraph = buildGraph.buildGraph {
      workspacePath = ../.;
      metadata = metadata;
      resolved = resolved;
      buildTarget = "x86_64-unknown-linux-gnu";
      hostTarget = "x86_64-unknown-linux-gnu";
      # TODO(phlip9): only works on ^^^
      pkgsCross = pkgs;
    };
  };

  meta = {
    license = lib.licenses.mit;
    mainProgram = "nargo-metadata";
  };
}
