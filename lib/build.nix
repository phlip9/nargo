{
  buildCrate,
  lib,
  resolve,
  targetCfg,
  vendorCargoDep,
}: rec {
  build = {
    # Path to cargo workspace root directory.
    workspacePath,
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
            # Internal: place each workspace package into its own store path.
            # Isolating each package is a prerequisite for perfect builds,
            # otherwise touching one workspace crate will cause all others to
            # also recompile.
            else if !(pkgMetadata ? source)
            then (_srcForWorkspacePkg workspacePath pkgId pkgMetadata)
            #
            else throw "nargo: error: unsure how to get crate source for package: ${pkgId}";
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

                    maybePkgUnitsCustomBuild = pkgUnits.custom-build or null;
                    # "${pkgId} > ${featFor} > custom-build"

                    # the build-script unit (or null), but only if we're not the
                    # build-script itself. we separate this case from the other
                    # deps since it gets handled very differently.
                    buildScriptDep =
                      if isBuildKind
                      then null
                      else maybePkgUnitsCustomBuild;

                    # bins, examples, tests, etc... depend on the lib target if
                    # it exists. Notably the lib target must also be linkable.
                    maybePkgUnitsLinkableLib = let
                      pkgLibUnit = pkgUnits.lib;
                      pkgLibTarget = pkgLibUnit.target;
                    in
                      if
                        (pkgUnits ? lib)
                        # only if lib has a "linkable" output
                        && (builtins.any (t: t == "lib" || t == "proc-macro" || t == "dylib" || t == "rlib") pkgLibTarget.crate_types)
                      # then ["${pkgId} > ${featFor} > lib"]
                      then [(_mkTargetDep pkgLibTarget.crate_name pkgLibUnit pkgLibTarget)]
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
                      is_proc_macro = isProcMacroKind;
                      crate_types = target.crate_types;
                      crate_name = builtins.replaceStrings ["-"] ["_"] target.name;
                      path = target.path;
                      edition = target.edition;
                      features = resolvedPkg.${featFor}.feats;
                      build_script_dep = buildScriptDep;
                      deps = intraPkgUnitDeps ++ interPkgUnitDeps;
                    };
                  in {
                    name = unitName;
                    # value = {target = buildTarget;};
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

    kind = target.kind;
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

        pkgUnitsByFeatFor = pkgs.${depPkgId};
        depIsProcMacro = _pkgContainsProcMacroTarget pkgUnitsByFeatFor;

        depFeatFor =
          if depIsProcMacro
          then "build"
          else depFeatForNoProcMacro;

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

        depUnit = pkgUnitsByFeatFor.${depFeatFor}.lib;
      in
        if relevantPkgDepKinds != []
        # TODO(phlip9): build scripts: for each dep that has a `links` key, also
        # depend on dep's build script
        # then ["${depPkgId} > ${depFeatFor} > lib"]
        then [(_mkTargetDep pkgDepName depUnit depUnit.target)]
        else []
    )
    depPkgIds;

  _isActivatedForPlatform = cfgs: pkgDepKind:
    if ! (pkgDepKind ? target)
    then true
    else targetCfg.evalCfgExpr cfgs (targetCfg.parseTargetCfgExpr pkgDepKind.target);

  _pkgContainsProcMacroTarget = pkg:
    (pkg ? build) && pkg.build.lib.target.is_proc_macro;

  _mkTargetDep = depName: unit: target: {
    crate_name = target.crate_name;
    dep_name = depName;
    unit = unit;
  };

  # Vendor workspace packages into their own isolated store path. We need a
  # little more granularity than just vendoring the whole package workspace path
  # so we can handle workspaces with a top-level root package.
  _srcForWorkspacePkg = workspacePath: pkgId: pkgMetadata: let
    # "crates/nargo-metadata#0.1.0" -> "crates/nargo-metadata"
    pkgWorkspaceRelPath = builtins.head (builtins.split "#" pkgId);
    pkgWorkspacePath = workspacePath + "/${pkgWorkspaceRelPath}";

    CargoToml = pkgWorkspacePath + "/Cargo.toml";
    src = pkgWorkspacePath + "/src";
    benches = pkgWorkspacePath + "/benches";
    examples = pkgWorkspacePath + "/examples";
    tests = pkgWorkspacePath + "/tests";
  in
    lib.fileset.toSource {
      root = pkgWorkspacePath;
      fileset = lib.fileset.unions [
        CargoToml
        src
        (lib.fileset.maybeMissing benches)
        (lib.fileset.maybeMissing examples)
        (lib.fileset.maybeMissing tests)
      ];
    };
}
