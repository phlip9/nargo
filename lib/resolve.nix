#
# Cargo feature resolution algorithm
#
{lib}: let
  inherit (lib) systems;
  # inherit (builtins) elemAt head length fromJSON readFile;
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
    # # Immutable context needed for feature resolution.
    ctx = {
      pkgs = metadata.packages;
      buildTarget = buildTarget;
      buildPlatform = buildPlatform;
      hostTarget = hostTarget;
      hostPlatform = hostPlatform;
    };

    rootFeaturesWithDefault =
      if noDefaultFeatures
      then rootFeatures
      else (rootFeatures ++ ["default"]);
  in
    builtins.genericClosure {
      startSet = _mkStartSet ctx rootPkgIds rootFeaturesWithDefault;

      # operator gets called _exactly once_ for each `key`
      operator = {key}:
        if builtins.length key == 2
        then (_activatePkg ctx (builtins.elemAt key 0) (builtins.elemAt key 1))
        else (_activateFv ctx (builtins.elemAt key 0) (builtins.elemAt key 1) (builtins.elemAt key 2));
    };

  # Activate a package with id `pkgId` for resovler target `featFor`.
  # This fn gets called _exactly once_ per `(pkgId, featFor)`.
  _activatePkg = ctx: pkgId: featFor: let
    # Skip optional deps here. We'll activate them if their associated feature
    # is enabled in `_activateFv`.
    nonOptional =
      builtins.filter
      (idFeatKind: !(builtins.elemAt idFeatKind 2).optional or false)
      (_pkgDepsFiltered ctx pkgId featFor);
  in
    # Convert the filtered deps into the expected `genericClosure` format
    builtins.map
    (idFeatKind: {key = [(builtins.elemAt idFeatKind 0) (builtins.elemAt idFeatKind 1)];})
    nonOptional;

  _activateFv = ctx: pkgId: featFor: feat: [];

  # Get the target-activated package dependencies for `pkgId` when it's
  # evaluated as a `featFor` dep (i.e., "build" vs "normal" dep).
  #
  # The `featFor` kind also propagates to each dep, so a (`pkgId`, "normal") dep
  # has a `kind == "build"` dep, we'll yield that dep as a "build" dep. OTOH, if
  # we're evaluating `pkgId` as a "build" dep, all returned deps willl also be
  # "build" deps.
  #
  # (pkg, normal) + (dep, normal) -> (dep, normal)
  # (pkg, normal) + (dep, build)  -> (dep, build)
  # (pkg, build)  + (dep, normal) -> (dep, build)
  # (pkg, build)  + (dep, build)  -> (dep, build)
  #
  # :: (Ctx, PkgId, FeatFor) -> [ [ DepPkgId FeatFor PkgDepKind ] ]
  _pkgDepsFiltered = ctx: pkgId: featFor: let
    deps = ctx.pkgs.${pkgId}.deps;
    depPkgIds = builtins.attrNames deps;
  in
    builtins.concatMap
    (
      depPkgId: let
        pkgDep = deps.${depPkgId};

        # Filter out any irrelevant dep entries (dev deps, inactive platform)
        # TODO: support resolver v1
        relevantPkgDepKinds =
          builtins.filter
          (
            pkgDepKind:
            # # Ignore dev deps
              ((pkgDepKind.kind or null) != "dev")
              # Check target `cfg()` etc
              && (_isActivatedForPlatform ctx featFor pkgDepKind)
          )
          pkgDep.kinds;
      in
        # Update the featFor's
        builtins.map
        (
          # The dep may be built for multiple targets. Ex: it can be used as a
          # normal dep for the primary target and also as a build dep (or normal
          # dep of a build dep).
          pkgDepKind: let
            depFeatFor =
              if featFor == "normal"
              then
                (
                  if ((pkgDepKind.kind or null) == "build") || (_pkgContainsProcMacroTarget ctx.pkgs.${depPkgId})
                  then "build"
                  else featFor
                )
              else "build";
          in [depPkgId depFeatFor pkgDepKind]
        )
        relevantPkgDepKinds
    )
    depPkgIds;

  # Is the dep activated for `featFor`, given the user's build platform and/or
  # target host platform (ex: --target=x86_64-unknown-linux-gnu).
  #
  # TODO
  _isActivatedForPlatform = ctx: featFor: pkgDepKind: true;

  # Build the initial set of workspace packages and features to activate.
  _mkStartSet = ctx: rootPkgIds: rootFeatures: let
    # The initially selected set of workspace packages to activate.
    startSetWithoutFeatures =
      builtins.concatMap (
        pkgId:
          [{key = [pkgId "normal"];}]
          ++ (
            # proc-macro crates in the workspace get activated as both a normal
            # and build.
            if (_pkgContainsProcMacroTarget ctx.pkgs.${pkgId})
            then [{key = [pkgId "build"];}]
            else []
          )
      )
      rootPkgIds;

    # Activate the root features for all selected workspace packages.
    startSetWithFeatures =
      builtins.concatMap (
        activation: let
          pkgId = builtins.elemAt activation.key 0;
          pkgFeats = ctx.pkgs.${pkgId}.features;
          # Only activate root features the pkg actually has.
          relevantRootFeats = builtins.filter (feat: pkgFeats ? ${feat}) rootFeatures;
        in
          builtins.map (feat: {key = activation.key ++ [feat];}) relevantRootFeats
      )
      startSetWithoutFeatures;
  in
    startSetWithFeatures ++ startSetWithoutFeatures;

  _pkgContainsProcMacroTarget = pkg:
    builtins.any (target:
      builtins.any (kind: kind == "proc-macro") target.kind)
    pkg.targets;
}
