{
  buildCrate,
  lib,
  resolve,
  targetCfg,
  vendorCargoDep,
}: rec {
  build = {
    # JSON-deserialized `Cargo.metadata.json`
    metadata,
    # The package set with all features resolved.
    # ```
    # {
    #   "#anyhow@1.0.86" = {
    #     build = { feats = { default = null; std = null; }; deps = {}; };
    #     normal = { ... };
    #   };
    # }
    # ```
    resolved,
    #
    buildTarget,
    buildPlatform ? lib.systems.elaborate buildTarget,
    hostTarget,
    hostPlatform ? lib.systems.elaborate hostTarget,
    # TODO(phlip9): target selection
    rootPkgIds ? metadata.workspace_default_members,
    # A nixpkgs instance where
    # `pkgsBuildBuild` is for `buildPlatform` and
    # `pkgsBuildTarget` is for `hostPlatform`
    pkgsCross,
  }: let
    metadataPkgs = metadata.packages;

    buildCfgs = targetCfg.platformToCfgs buildPlatform;
    hostCfgs = targetCfg.platformToCfgs hostPlatform;

    # TODO(phlip9): discover target cfgs with `rustc --print=cfg`. Do we also
    # need some fancy fixpoint iteration a la
    # `cargo::core::compiler::build_context::target_info::TargetInfo::new`?

    pkgs =
      builtins.mapAttrs (
        pkgId: resolvedPkg: let
          pkgMetadata = metadataPkgs.${pkgId};

          crateSrc =
            # External: if we're using `craneLib.vendorCargoDeps`, we should
            # have a `path` attr that contains the vendored crate source.
            if (pkgMetadata ? path)
            then pkgMetadata.path
            # External: if we're using `nargo-metadata --nix-prefetch`, we
            # should have a pinned crates.io `hash` attr.
            else if (pkgMetadata ? hash)
            then (vendorCargoDep pkgMetadata)
            # TODO(phlip9): workspace crate path
            else throw "workspace crates not supported yet";
        in
          builtins.mapAttrs (
            featFor: resolvedPkgFeatFor: let
              cfgs =
                if featFor == "build"
                then buildCfgs
                else hostCfgs;

              pkgUnits =
                builtins.listToAttrs
                (builtins.map (target: let
                    kind = target.kind;

                    isLibKind = kind == "lib";
                    isBuildKind = kind == "custom-build";
                    isProcMacroKind = builtins.elem "proc-macro" target.crate_types;

                    unitName =
                      if isLibKind || isBuildKind || isProcMacroKind
                      then kind
                      else "${kind}-${target.name}";

                    maybePkgUnitsCustomBuild =
                      if pkgUnits ? "custom-build"
                      then pkgUnits."custom-build"
                      # then ["${pkgId} > ${featFor} > custom-build"]
                      else null;

                    # the build-script unit (or null), but only if we're not the
                    # build-script itself. we separate this case from the other
                    # deps since it gets handled very differently.
                    buildScriptDep =
                      if isBuildKind
                      then null
                      else maybePkgUnitsCustomBuild;

                    # bins, examples, tests, etc... depend on the lib target if
                    # it exists. Notably the lib target must also be linkable.
                    maybePkgUnitsLinkableLib =
                      if
                        (pkgUnits ? lib)
                        # only if lib has a "linkable" output
                        && (builtins.any (t: t == "lib" || t == "proc-macro" || t == "dylib" || t == "rlib") pkgUnits.lib.crate_types)
                      # then [pkgUnits.lib]
                      then ["${pkgId} > ${featFor} > lib"]
                      else [];

                    # non-build script dependencies on other units within the
                    # same package.
                    intraPkgUnitDeps =
                      if isLibKind || isBuildKind
                      then []
                      else maybePkgUnitsLinkableLib;

                    # Dependencies on other lib/proc-macro units in other packages.
                    interPkgUnitDeps = _pkgDeps pkgs pkgMetadata resolvedPkg featFor cfgs resolvedPkgFeatFor.deps target;

                    buildTarget = {
                      name = target.name;
                      kind = kind;
                      # crate_name = builtins.replaceStrings ["-"] ["_"] target.name;
                      crate_types = target.crate_types;
                      path = target.path;
                      edition = target.edition;
                      features = resolvedPkg.${featFor}.feats;
                      deps = intraPkgUnitDeps ++ interPkgUnitDeps;
                      build_script_dep = buildScriptDep;
                    };
                  in {
                    name = unitName;
                    value = buildCrate {
                      # TODO(phlip9): choose right package set by build/hostTarget?
                      pkgs = pkgsCross;
                      pkgMetadata = pkgMetadata;
                      crateSrc = crateSrc;
                      target = buildTarget;
                    };
                  })
                  pkgMetadata.targets);
            in
              pkgUnits
          )
          resolvedPkg
      )
      resolved;
  in
    pkgs;

  _pkgDeps = pkgs: pkgMetadata: resolvedPkg: featFor: cfgs: activatedDeps: target: let
    deps = pkgMetadata.deps;
    depPkgIds = builtins.attrNames deps;

    kind = builtins.head target.kind;
    isBuildKind = kind == "custom-build";

    # TODO(phlip9): support dev deps
    depFeatForNoProcMacro =
      if isBuildKind
      then "build"
      else featFor;

    desiredDepKind =
      if isBuildKind
      then "build"
      else null;
  in
    builtins.concatMap
    (
      depPkgId: let
        pkgDep = deps.${depPkgId};
        pkgDepName = pkgDep.name;

        depIsProcMacro = _pkgContainsProcMacroTarget pkgs.${depPkgId};

        depFeatFor =
          if depIsProcMacro
          then "build"
          else depFeatForNoProcMacro;

        unitName =
          if depIsProcMacro
          then "proc-macro"
          else "lib";

        relevantPkgDepKinds =
          builtins.filter (
            pkgDepKind:
              ((pkgDepKind.kind or null) == desiredDepKind)
              # only select optional deps that are activated
              && ((pkgDepKind.optional or false) -> activatedDeps ? ${pkgDepName})
              # make sure the dep is activated for this target cfg
              && (_isActivatedForPlatform cfgs pkgDepKind)
          )
          pkgDep.kinds;
      in
        if relevantPkgDepKinds != []
        # TODO(phlip9): build scripts: for each dep that has a `links` key, also
        # depend on dep's build script
        then ["${depPkgId} > ${depFeatFor} > ${unitName}"]
        else []
    )
    depPkgIds;

  _isActivatedForPlatform = cfgs: pkgDepKind:
    if ! (pkgDepKind ? target)
    then true
    else targetCfg.evalCfgExpr cfgs (targetCfg.parseTargetCfgExpr pkgDepKind.target);

  _pkgContainsProcMacroTarget = pkg: (pkg ? build) && (pkg.build ? "proc-macro");
}
