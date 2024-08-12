{
  lib,
  resolve,
  targetCfg,
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
    #
    rootPkgIds ? metadata.workspace_default_members,
  }: let
    metadataPkgs = metadata.packages;

    ctx = {
      pkgs = metadata.packages;
      buildCfgs = targetCfg.platformToCfgs buildPlatform;
      hostCfgs = targetCfg.platformToCfgs hostPlatform;
      prevResolved = resolved;
    };

    # pkgs = builtins.mapAttrs (pkgId: pkgMetadata: let
    #   # (pkgMetadata, target) -> proposals
    #   # filter proposals -> units (w/o deps)
    #   # units with deps
    #   isWorkspacePkg = !(pkgMetadata ? source);
    #
    #   units = builtins.con
    #     pkgMetadata.targets;
    # in {
    # });
    pkgsBuild =
      builtins.mapAttrs (
        pkgId: resolvedPkg: let
          pkgMetadata = metadataPkgs.${pkgId};

          pkgUnits =
            builtins.listToAttrs
            (builtins.map (target: let
                kind = builtins.head target.kind;

                isLibKind = kind == "lib";
                isBuildKind = kind == "custom-build";

                unitName =
                  if isLibKind || isBuildKind
                  then kind
                  else "${kind}-${target.name}";

                maybePkgUnitsCustomBuild =
                  if pkgUnits ? "custom-build"
                  then [pkgUnits."custom-build"]
                  else [];
                maybePkgUnitsLib =
                  if pkgUnits ? lib
                  then [pkgUnits.lib]
                  else [];

                # Dependencies on other units within the same package.
                intraPkgUnitDeps =
                  if isLibKind
                  then maybePkgUnitsCustomBuild
                  else if isBuildKind
                  then []
                  else maybePkgUnitsLib ++ maybePkgUnitsCustomBuild;

                # Dependencies on other units in other packages.
                # TODO(phlip9): will need to get dev deps for dev targets
                interPkgUnitDeps =
                  builtins.map
                  (idFeatKindName: pkgsBuild.${builtins.elemAt idFeatKindName 0}.lib)
                  (resolve._pkgDepsFiltered ctx pkgId "build" (
                    pkgDepName: pkgDepKind:
                      (
                        if isBuildKind
                        then (pkgDepKind.kind or null) == "build"
                        # TODO(phlip9): handle dev targets
                        else !(pkgDepKind ? kind)
                      )
                      && ((pkgDepKind.optional or false) -> (resolvedPkg.build.deps ? ${pkgDepName}))
                  ));
              in {
                name = unitName;
                value = {
                  name = target.name;
                  kind = kind;
                  crate_types = target.crate_types;
                  path = target.path;
                  edition = target.edition;
                  features = resolvedPkg.build.feats;
                  deps = intraPkgUnitDeps ++ interPkgUnitDeps;
                };
              })
              pkgMetadata.targets);
        in
          if !(resolvedPkg ? build)
          then null
          else pkgUnits
      )
      resolved;
  in
    pkgsBuild;
}
