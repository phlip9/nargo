# This derivation builds the `nargo-metadata` binary, which we use to generate
# the `Cargo.metadata.json` file in a cargo workspace.
#
# cargo build -p nargo-metadata --bin nargo-metadata
{
  buildPackage,
  pkgs,
}:
buildPackage {
  workspacePath = ../.;
  pkgsCross = pkgs;
  packages = ["nargo-metadata"];
  bins = ["nargo-metadata"];
}
# craneLib.buildPackage rec {
#   pname = "nargo-metadata";
#   version = "0.1.0";
#
#   cargoVendorDir = nargoVendoredCargoDeps;
#   src = lib.fileset.toSource {
#     root = ../.;
#     fileset = lib.fileset.unions [
#       ../Cargo.toml
#       ../Cargo.lock
#       ../.cargo
#       ../crates/nargo-core
#       ../crates/nargo-metadata
#       ../crates/nargo-resolve/Cargo.toml
#       ../crates/nargo-resolve/src/lib.rs
#       ../crates/nargo-rustc/Cargo.toml
#       ../crates/nargo-rustc/src/lib.rs
#     ];
#   };
#
#   cargoExtraArgs = "-p nargo-metadata --bin nargo-metadata";
#
#   cargoArtifacts = null;
#   doCheck = false;
#   doInstallCargoArtifacts = false;
#   strictDeps = true;
#
#   passthru = rec {
#     workspacePath = ../.;
#     buildTarget = "x86_64-unknown-linux-gnu";
#     hostTarget = "x86_64-unknown-linux-gnu";
#     rootPkgIds = ["nargo-metadata"];
#
#     build-plan = generateCargoBuildPlan {
#       name = pname;
#       src = src;
#       cargoVendorDir = nargoVendoredCargoDeps;
#       cargoExtraArgs = cargoExtraArgs;
#       hostTarget = hostTarget;
#     };
#
#     metadataDrv = generateCargoMetadata {
#       name = pname;
#       src = src;
#       cargoVendorDir = nargoVendoredCargoDeps;
#     };
#
#     metadata = builtins.fromJSON (builtins.readFile ../Cargo.metadata.json);
#
#     resolved = resolve.resolveFeatures {
#       metadata = metadata;
#       buildTarget = buildTarget;
#       hostTarget = hostTarget;
#       rootPkgIds = rootPkgIds;
#     };
#
#     builtCrates = buildGraph.buildGraph {
#       workspacePath = ../.;
#       metadata = metadata;
#       resolved = resolved;
#       rootPkgIds = rootPkgIds;
#       buildTarget = buildTarget;
#       hostTarget = hostTarget;
#       # TODO(phlip9): only works on ^^^
#       pkgsCross = pkgs;
#     };
#
#     built = buildPackage {
#       workspacePath = workspacePath;
#       metadata = metadata;
#       pkgsCross = pkgs;
#       # pname = pname;
#       # version = version;
#       packages = ["nargo-metadata"];
#       bins = ["nargo-metadata"];
#     };
#   };
#
#   meta = {
#     license = lib.licenses.mit;
#     mainProgram = "nargo-metadata";
#   };
# }

