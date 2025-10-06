{
  buildGraph,
  lib,
  resolve,
  pkgs,
}:
#
# # nargo.buildPackage
#
# The high-level interface to build rust packages.
{
  pname ? throw "nargo: error: missing `pname` for multi-target build",
  version ? throw "nargo: error: missing `version` for multi-target build",
  #
  # # Manifest Options:
  #
  # Path to cargo workspace root directory.
  workspacePath,
  # Path to workspace `Cargo.metadata.json`.
  metadataPath ? workspacePath + "/Cargo.metadata.json",
  # JSON-deserialized workspace `Cargo.metadata.json`.
  metadata ? builtins.fromJSON (builtins.readFile metadataPath),
  #
  # # Compilation Options:
  #
  # TODO(phlip9): needs rework
  buildTarget ? pkgsCross.buildPlatform.rust.rustcTarget,
  buildPlatform ? pkgsCross.buildPlatform,
  hostTarget ? pkgsCross.hostPlatform.rust.rustcTarget,
  hostPlatform ? pkgsCross.hostPlatform,
  # A nixpkgs instance where
  # `pkgsBuildBuild` is for `buildPlatform` and
  # `pkgsBuildTarget` is for `hostPlatform`
  pkgsCross ? pkgs.pkgsCross.${hostTarget},
  # TODO(phlip9): select profile (--release, --profile <name>)
  #
  # # Package Selection:
  #
  # A list of the root package(s) we're going to build.
  #
  # The behavior mirrors `cargo`; leaving it unset will build all default
  # workspace members. Setting it explicitly like `["foo" "bar"]` will only
  # build targets from the `foo` and `bar` workspace packages. The equivalent
  # for cargo would be `cargo build -p foo -p bar`.
  #
  # Ex: `[ "age-plugin" "rage" ]`
  packages ? metadata.workspace_default_members,
  #
  # # Target Selection:
  #
  # Build package libraries (ex: *.rlib, *.so, *.dylib).
  # TODO(phlip9): allow selecting specific library crate-types, like `cargo rustc`.
  lib ? false,
  # Build package binaries.
  # You can also set this arg to a list of specific binaries to build
  # Ex: `true`, `false`, `[ "nargo-rustc" "nargo-metadata" ]`.
  bins ? true,
  # TODO(phlip9): --examples, --tests, --benches, --all-targets
  #
  # # Feature Selection:
  #
  # TODO(phlip9): --all-features
  # The features to activate for all selected `packages` in the workspace.
  # Like `cargo build --features=derive,vendored-openssl`.
  features ? [],
  # If true, don't enable the "default" features for the selected workspace
  # packages.
  noDefaultFeatures ? false,
  # The build graph of all selected crates, from `buildGraph.buildGraph`.
  # ```
  # {
  #   "proc-macro2@1.0.86" = {
  #     build = {
  #       custom-build = buildCrate { .. };
  #       lib = buildCrate { .. };
  #     };
  #   };
  #   "itoa@1.0.11" = {
  #     normal = {
  #       lib = buildCrate { .. };
  #     };
  #   };
  #   "nargo-metadata" = {
  #     normal = {
  #       bin-nargo-metadata = buildCrate { .. };
  #       lib = buildCrate { .. };
  #     };
  #   };
  # };
  # ```
  builtCrates ?
    buildGraph.buildGraph {
      inherit workspacePath metadataPath metadata buildTarget buildPlatform hostTarget hostPlatform pkgsCross;
      rootPkgIds = packages;
      resolved = resolve.resolveFeatures {
        inherit metadata noDefaultFeatures buildTarget buildPlatform hostTarget hostPlatform;
        rootPkgIds = packages;
        rootFeatures = features;
      };
    },
}:
#
let
  allTargets = (lib == true) && (bins == true);

  # Build the list of all selected package targets.
  selectedPkgs = builtins.concatMap (pkgId: selectPkgFeatFor builtCrates.${pkgId}) packages;
  selectPkgFeatFor = pkgFeatFor:
    if !(pkgFeatFor ? normal)
    then []
    else selectPkgFeatForTargets pkgFeatFor.normal;
  selectPkgFeatForTargets = pkgTargets:
    if allTargets
    then builtins.attrValues pkgTargets
    else
      builtins.map
      (targetName: pkgTargets.${targetName})
      (builtins.filter selectTargetName (builtins.attrNames pkgTargets));
  selectTargetName = targetName:
    (lib == true && targetName == "lib")
    || (bins == true && stringStartsWith "bin-" targetName)
    || (builtins.isList bins
      && stringStartsWith "bin-" targetName
      && builtins.any (bin: "bin-${bin}" == targetName) bins);

  # `str.startsWith(prefix)`
  stringStartsWith = prefix: str:
    (builtins.stringLength str >= builtins.stringLength prefix)
    && ((builtins.substring 0 (builtins.stringLength prefix) str) == prefix);

  numSelected = builtins.length selectedPkgs;
in
  if numSelected == 0
  then
    throw ''
      nargo: error: No targets selected. `packages` probably contains non-existent
      packages or the target filters are too strict.

      Available packages: ${builtins.toJSON metadata.workspace_members}

      Current target filters:
      lib = ${builtins.toJSON lib}
      bins = ${builtins.toJSON bins}
      packages = ${builtins.toJSON packages}
    ''
  else if numSelected == 1
  then builtins.elemAt selectedPkgs 0
  else
    pkgs.symlinkJoin {
      pname = pname;
      version = version;
      paths = selectedPkgs;
    }
