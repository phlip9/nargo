#
# Cargo feature resolution algorithm
#
{lib}: let
  inherit (lib) systems;
  inherit (builtins) elemAt head length fromJSON readFile;
in rec {
  # From the full, locked package set in `Cargo.metadata.json` and a concrete
  # build instance (workspace packages, workspace targets, target platform,
  # features), this function resolves the features and optional dependencies
  # for all transitively selected packages.
  resolveFeatures = {
    # JSON-deserialized `Cargo.metadata.json`
    metadata,
    # A list of the root package(s) we're going to build.
    #
    # The behavior mirrors `cargo`; leaving it unset will build all default
    # workspace members. Setting it explicitly like `cargo build -p foo` will
    # only build the `foo` package.
    #
    # Ex: `[ "age-plugin#0.5.0" "rage#0.10.0" ]`
    rootPkgIds ? metadata.workspace_default_members,
    # The features to activate for all `rootPkgIds` in the workspace.
    #
    # Like `cargo build --features=derive,vendored-openssl`
    #
    # Ex: `[ "derive" "vendored-openssl" ]`
    # TODO(phlip9): --all-features
    rootFeatures ? [],
    # If true, don't enable the "default" features for the selected workspace
    # packages.
    noDefaultFeatures ? false,
    # The build platform, as a rust target triple.
    # Ex: "x86_64-unknown-linux-gnu", "aarch64-linux-android"
    buildTarget,
    # The elaborated build platform, used to build and run cargo build.rs
    # scripts or proc-macros. All `[build-dependencies]` and their transitive
    # deps are cfg'd based on this platform.
    #
    # Typically `stdenv.buildPlatform`.
    buildPlatform ? systems.elaborate buildTarget,
    # The runtime/host platform, as a rust target triple.
    # Ex: "x86_64-unknown-linux-gnu", "aarch64-linux-android"
    hostTarget,
    # The host platform we're targetting for the final produced artifacts
    # (binaries, libraries, tests, etc...). Here we're using "host" in the
    # nixpkgs sense (runtime platform) and not the cargo sense (build platform).
    #
    # Like `cargo build --target=x86_64-unknown-linux-gnu`
    #
    # Typically `stdenv.hostPlatform`.
    # TODO(phlip9): support multiple target platforms
    hostPlatform ? systems.elaborate hostTarget,
  }: let
    # Immutable context needed for feature resolution.
    ctx = {
      metadata = metadata;
      buildTarget = buildTarget;
      buildPlatform = buildPlatform;
      hostTarget = hostTarget;
      hostPlatform = hostPlatform;
    };

    # Feature resolution state to accumulate
    state = {};
  in {};
  # _resolveFeaturesGo {
  #   inherit ctx rootPkgIds rootFeatures noDefaultFeatures state;
  #   idx = 0;
  # };

  # _resolveFeaturesGo = {
  #   ctx,
  #   rootPkgIds,
  #   rootFeatures,
  #   noDefaultFeatures,
  #   idx,
  #   state,
  # }:
  #   if idx == length rootPkgIds
  #   then _finalizeOutput {inherit ctx state;}
  #   else let
  #     nextState = _enableWorkspacePkg {
  #       inherit ctx rootFeatures noDefaultFeatures state;
  #       rootPkgId = elemAt rootPkgIds idx;
  #     };
  #   in {};
  #
  # _enableWorkspacePkg = {
  #   ctx,
  #   rootPkgId,
  #   rootFeatures,
  #   noDefaultFeatures,
  #   state,
  # }:
  #   state;
  #
  # _finalizeOutput = {
  #   ctx,
  #   state,
  # }:
  #   state;
}
