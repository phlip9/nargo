#
# Cargo feature resolution algorithm
#
{
  lib,
  targetCfg,
}: rec {
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
    buildPlatform ? lib.systems.elaborate buildTarget,
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
    hostPlatform ? lib.systems.elaborate hostTarget,
  }: let
    # Immutable context needed for feature resolution.
    ctx = {
      pkgs = metadata.packages;
      buildCfgs = targetCfg.platformToCfgs buildPlatform;
      hostCfgs = targetCfg.platformToCfgs hostPlatform;
    };

    rootFeaturesWithDefault =
      if noDefaultFeatures
      then rootFeatures
      else (rootFeatures ++ ["default"]);

    # This `genericClosure` call effectively walks the (pkgId, featFor, feat?)
    # tree, calling `operator` exactly once for each `key`.
    #
    # Returns a list that looks like:
    # ```
    # [ { key = [ "crates/nargo-metadata#0.1.0" "normal" ]; }
    #   { key = [ "#anyhow@1.0.86" "normal" "default" ]; }
    #   { key = [ "#anyhow@1.0.86" "normal" ]; }
    #   { key = [ "#quote@1.0.36" "build" "proc-macro2/proc-macro" ]; }
    #   { key = [ "#syn@2.0.68" "build" "dep:quote" ]; }
    #   { key = [ "#syn@2.0.68" "build" "proc-macro2/proc-macro" ]; } ]
    # ```
    #
    # Note: we can't use an attrset for the `key` since they're not comparable,
    # hence the list.
    activationsList = builtins.genericClosure {
      startSet = _mkStartSet ctx rootPkgIds rootFeaturesWithDefault;

      # operator gets called _exactly once_ for each `key`
      operator = {key}:
        if builtins.length key == 2
        then (_activatePkg ctx (builtins.elemAt key 0) (builtins.elemAt key 1))
        else (_activateFv ctx (builtins.elemAt key 0) (builtins.elemAt key 1) (builtins.elemAt key 2));
    };

    # Collect the `activationsList` into an attrset.
    #
    # {
    #   "#syn@2.0.68" = {
    #     build = {
    #       feats = {
    #         clone-impls = null;
    #         derive = null;
    #         parsing = null;
    #         printing = null;
    #         proc-macro = null;
    #       };
    #       deps = {
    #         quote = null;
    #         proc-macro2 = null;
    #       };
    #       deferred = [
    #         { depFeat = "proc-macro"; depName = "quote"; .. }
    #       ];
    #     }
    #   };
    # }
    #
    # TODO(phlip9): save actual `depPkgId` alongside `key` for `dep` and `depFeature`?
    activations =
      # groupBy: pkgId
      builtins.mapAttrs
      (
        # groupBy: featFor
        _pkgId: keys:
          builtins.mapAttrs (
            # {
            #   feats = { ... };
            #   deps = { ... };
            #   deferred = { ... };
            # }
            featFor: keys: let
              parsedFeats =
                builtins.map (
                  {key}:
                    if builtins.length key == 2
                    then {}
                    else (_parseFeature (builtins.elemAt key 2))
                )
                keys;

              # Activated optional deps
              deps = builtins.listToAttrs (
                builtins.map (feat: {
                  name = feat.depName;
                  value = null;
                })
                (
                  builtins.filter (
                    feat: let
                      type = feat.type or null;
                    in
                      type == "dep" || (type == "depFeature" && !(feat.weak or false))
                  )
                  parsedFeats
                )
              );
            in {
              # Activated normal features
              feats = builtins.listToAttrs (
                builtins.map (feat: {
                  name = feat.feat;
                  value = null;
                })
                (
                  builtins.filter (
                    feat:
                      (feat.type or null) == "normal"
                    # TODO(phlip9): don't think we can filter this out yet b/c
                    # of weak dep checks.
                    # && feat.feat != "default"
                  )
                  parsedFeats
                )
              );

              # Activated optional deps
              deps = deps;

              # Deferred weak deps
              deferred = (
                builtins.filter
                (
                  feat:
                    ((feat.type or null) == "depFeature")
                    && feat.weak
                    # We can pre-filter all weak dep features where the optional
                    # dependency was never activated.
                    && (deps ? ${feat.depName})
                )
                parsedFeats
              );
            }
          )
          (builtins.groupBy ({key}: builtins.elemAt key 1) keys)
      )
      (builtins.groupBy ({key}: builtins.elemAt key 0) activationsList);

    # Check if any deferred weak dep features are unsatisfied.
    # A weak dep feature is satisfied if:
    # 1. optional dep `depName` is _not_ activated (weak dep feature is disabled).
    #    This gets covered by the pre-filter above.
    # 2. optional dep `depName` is activated and that dep's `depFeat` is
    #    activated.
    # Otherwise we need to go for another round of feature resolution.
    unsatDeferred =
      builtins.mapAttrs
      (
        pkgId: byFeatFor:
          builtins.mapAttrs (
            featFor: {
              deferred,
              feats,
              deps,
            }:
              builtins.filter
              (
                idFeatKindName: let
                  depPkgId = builtins.elemAt idFeatKindName 0;
                  depFeatFor = builtins.elemAt idFeatKindName 1;
                  depPkgName = builtins.elemAt idFeatKindName 3;

                  depWeakFeat =
                    builtins.elemAt
                    (
                      builtins.filter
                      (weakFeat: weakFeat.depName == depPkgName)
                      deferred
                    )
                    0;
                in
                  # TODO(phlip9): do we need to check "dep:${depName}"?
                  !(activations.${depPkgId}.${depFeatFor}.feats ? ${depWeakFeat.depFeat})
              )
              (_pkgDepsFiltered ctx pkgId featFor (pkgDepName: pkgDepKind: (
                builtins.any (weakFeat: weakFeat.depName == pkgDepName) deferred
              )))
          )
          byFeatFor
      )
      activations;

    anyUnsatDeferred =
      builtins.any
      (byFeatFor:
        builtins.any
        (unsat: builtins.length unsat > 0)
        (builtins.attrValues byFeatFor))
      (builtins.attrValues unsatDeferred);
  in
    # activationsList;
    # TODO(phlip9): recurse if anyUnsatDeferred
    if anyUnsatDeferred
    then builtins.trace "WARN: unsatisfied deferred weak dependencies!" activations
    else activations;

  # Activate a package with id `pkgId` for resovler target `featFor`.
  # This fn gets called _exactly once_ per `(pkgId, featFor)`.
  _activatePkg = ctx: pkgId: featFor:
    builtins.concatMap
    _activateFilteredPkgDepFeatures
    # Skip optional deps here. We'll activate them later in `_activateFv`, if
    # their associated feature is enabled.
    (_pkgDepsFiltered ctx pkgId featFor (_pkgDepName: pkgDepKind: !(pkgDepKind.optional or false)));

  # activate a feature (dispatch to each `FeatureValue` handler)
  _activateFv = ctx: pkgId: featFor: feat: let
    parsedFeat = _parseFeature feat;
  in
    if parsedFeat.type == "normal"
    then _activateFvNormal ctx pkgId featFor parsedFeat.feat
    else if parsedFeat.type == "dep"
    then _activateFvDep ctx pkgId featFor parsedFeat.depName
    else if parsedFeat.type == "depFeature"
    then _activateFvDepFeature ctx pkgId featFor parsedFeat
    else throw "unknown feature type: ${feat}";

  # activate a normal feature (ex: "rt-multi-threaded")
  _activateFvNormal = ctx: pkgId: featFor: feat:
    builtins.map
    (pkgFeat: {key = [pkgId featFor pkgFeat];})
    (ctx.pkgs.${pkgId}.features.${feat});

  # activate an optional dep feature (ex: "dep:serde_derive")
  # TODO(phlip9): somehow handle weak dep feature upon activation
  _activateFvDep = ctx: pkgId: featFor: depName:
    builtins.concatMap
    _activateFilteredPkgDepFeatures
    (_pkgDepsFiltered ctx pkgId featFor (
      pkgDepName: pkgDepKind:
      # TODO(phlip9): is this `optional` check ok?
        (pkgDepKind.optional or false)
        && (pkgDepName == depName)
    ));

  # Activate a transitive dep feature (ex: "serde/std", "quote?/proc-macro")
  # NOTE: Currently we ignore all weak dep features
  # TODO(phlip9): produce weak dep feature correctly
  _activateFvDepFeature = ctx: pkgId: featFor: parsedFeat:
    if parsedFeat.weak
    then []
    else
      builtins.concatMap
      (
        idFeatKindName: let
          depPkgId = builtins.elemAt idFeatKindName 0;
          depFeatFor = builtins.elemAt idFeatKindName 1;
          depPkgDepKind = builtins.elemAt idFeatKindName 2;
        in
          # Activate the feature on the dependency itself
          [{key = [depPkgId depFeatFor parsedFeat.depFeat];}]
          ++ (
            # If the dep is optional, either enable that dep (if not weak) or if
            # weak, note it down to activate the feature if/when that dep is enabled
            # later on.
            # TODO(phlip9): actually handle weak
            if depPkgDepKind.optional or false
            then
              (
                # Activate the optional dep on self
                [{key = [pkgId featFor "dep:${parsedFeat.depName}"];}]
                ++ (
                  # Old behavior before weak deps were added was to enable a
                  # feature of the same name.
                  #
                  # Don't enable if the implicit optional dependency feature
                  # wasn't created due to `dep:` hiding.
                  if !parsedFeat.weak && ctx.pkgs.${pkgId}.features ? ${parsedFeat.depName}
                  then [{key = [pkgId featFor parsedFeat.depName];}]
                  else []
                )
              )
            else []
          )
      )
      (_pkgDepsFiltered ctx pkgId featFor
        (pkgDepName: _pkgDepKind: pkgDepName == parsedFeat.depName));

  # Get the target-activated package dependencies for `pkgId` when it's
  # evaluated as a `featFor` dep (i.e., "build" vs "normal" dep).
  #
  # The `featFor` kind also propagates to each dep, so a (`pkgId`, "normal") dep
  # has a `kind == "build"` dep, we'll yield that dep as a "build" dep. OTOH, if
  # we're evaluating `pkgId` as a "build" dep, all returned deps will also be
  # "build" deps.
  #
  # (pkg, normal) + (dep, normal) -> (dep, normal)
  # (pkg, normal) + (dep, build)  -> (dep, build)
  # (pkg, build)  + (dep, normal) -> (dep, build)
  # (pkg, build)  + (dep, build)  -> (dep, build)
  #
  # :: (Ctx, PkgId, FeatFor, (depName: pkgDepKind: -> bool)) -> [ [ DepPkgId FeatFor PkgDepKind PkgDepName ] ]
  _pkgDepsFiltered = ctx: pkgId: featFor: depFilter: let
    deps = ctx.pkgs.${pkgId}.deps;
    depPkgIds = builtins.attrNames deps;
  in
    builtins.concatMap
    (
      depPkgId: let
        pkgDep = deps.${depPkgId};
        pkgDepName = pkgDep.name;

        # Filter out any irrelevant dep entries (dev deps, inactive platform)
        # TODO(phlip9): support resolver v1
        # TODO(phlip9): support artifact deps
        relevantPkgDepKinds =
          builtins.filter
          (
            pkgDepKind:
            # # Always ignore dev deps
              ((pkgDepKind.kind or null) != "dev")
              # Check caller's filter
              && (depFilter pkgDepName pkgDepKind)
              # Check target `cfg()` etc
              && (_isActivatedForPlatform ctx featFor pkgDepKind)
          )
          pkgDep.kinds;

        depPkgContainsProcMacroTarget = _pkgContainsProcMacroTarget ctx.pkgs.${depPkgId};
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
                  if ((pkgDepKind.kind or null) == "build") || depPkgContainsProcMacroTarget
                  then "build"
                  else featFor
                )
              else "build";
          in [depPkgId depFeatFor pkgDepKind pkgDepName]
        )
        relevantPkgDepKinds
    )
    depPkgIds;

  # Activate the features for each dep returned from `_pkgDepsFiltered`.
  _activateFilteredPkgDepFeatures = idFeatKindName: let
    depPkgId = builtins.elemAt idFeatKindName 0;
    depFeatFor = builtins.elemAt idFeatKindName 1;
    depPkgDepKind = builtins.elemAt idFeatKindName 2;
    depFeatsWithDefault =
      (depPkgDepKind.features or [])
      ++ (
        if depPkgDepKind.default or true
        then ["default"]
        else []
      );
  in
    # the dep feature activations: `[<depPkgId> <depFeatFor> <depFeat>]`
    (builtins.map (depFeat: {key = [depPkgId depFeatFor depFeat];}) depFeatsWithDefault)
    # the dep pkg activation: `[<depPkgId> <depFeatFor>]`
    ++ [{key = [depPkgId depFeatFor];}];

  # Is the dep activated for `featFor`, given the user's build platform and/or
  # target host platform (ex: --target=x86_64-unknown-linux-gnu).
  # TODO(phlip9): support artifact deps
  _isActivatedForPlatform = ctx: featFor: pkgDepKind:
    if ! (pkgDepKind ? target)
    # No `cfg(...)` or platform specifier => always activate
    then true
    else
      # Evaluate the `cfg(...)` expr against the target platform for this pkgDep.
      targetCfg.evalCfgExpr (
        if ((featFor == "build") || ((pkgDepKind.kind or null) == "build"))
        then ctx.buildCfgs
        else ctx.hostCfgs
      )
      (targetCfg.parseTargetCfgExpr pkgDepKind.target);

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
    builtins.any
    (target: builtins.any (kind: kind == "proc-macro") target.kind)
    pkg.targets;

  # Parse a raw feature string into a `FeatureValue`:
  #
  # ```rust
  # enum FeatureValue {
  #   Feature(String),
  #   Dep { dep_name: String },
  #   DepFeature { dep_name: String, dep_feature: String, weak: bool },
  # }
  # ```
  _parseFeature = feat: let
    isDep = builtins.match "dep:(.*)" feat;
    isDepFeature = builtins.match "([^?]*)([?])?/(.*)" feat;
  in
    if isDep != null
    then {
      type = "dep";
      depName = builtins.head isDep;
    }
    else if isDepFeature != null
    then {
      type = "depFeature";
      depName = builtins.elemAt isDepFeature 0;
      weak = (builtins.elemAt isDepFeature 1) != null;
      depFeat = builtins.elemAt isDepFeature 2;
    }
    else {
      type = "normal";
      feat = feat;
    };
}
