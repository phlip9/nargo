{
  self,
  pkgs,
  inputs,
}: let
  lib = inputs.nixpkgs.lib;
  nocargo-lib = import ../../lib {inherit lib;};
  craneLib = inputs.crane.mkLib pkgs;

  inherit
    (builtins)
    all
    baseNameOf
    concatLists
    elemAt
    foldl'
    fromTOML
    length
    match
    partition
    pathExists
    readDir
    readFile
    substring
    toInt
    toJSON
    ;
  inherit
    (lib)
    assertMsg
    findFirst
    flatten
    foldlAttrs
    hasSuffix
    isDerivation
    isString
    listToAttrs
    mapAttrsToList
    mapNullable
    optional
    optionalAttrs
    removePrefix
    removeSuffix
    replaceStrings
    runTests
    subtractLists
    ;
  inherit (nocargo-lib.pkg-info) toPkgId;
  inherit (nocargo-lib.glob) globMatchDir;
  inherit (nocargo-lib.support) sanitizeRelativePath;

  # dbg = x: builtins.trace x x;
  # dbgJson = x: builtins.trace (builtins.toJSON x) x;
  # logJson = label: x: builtins.trace (label + builtins.toJSON x) x;
  # traceJson = x: y: builtins.trace (builtins.toJSON x) y;

  # filterMap = fn: xs:
  #   foldl'
  #   (xs: y: let
  #     x = fn y;
  #   in
  #     if x != null
  #     then xs ++ x
  #     else xs)
  #   []
  #   fn;

  # onlyIf = pred: x:
  #   if pred x
  #   then x
  #   else null;

  # optionToList = x:
  #   if x != null
  #   then [x]
  #   else [];

  orElse = x: y:
    if x != null
    then x
    else y;

  # defaultRegistries = {
  #   "https://github.com/rust-lang/crates.io-index" =
  #     nocargo-lib.pkg-info.mkIndex
  #     pkgs.fetchurl
  #     inputs.registry-crates-io
  #     (import ../../crates-io-override {inherit lib pkgs;});
  # };

  # Run `cargo metadata` on a crate or workspace in `src`.
  cargoMetadata = {
    pkgs,
    src,
    name,
  }:
    pkgs.runCommandLocal "${name}.cargo-metadata.json" {
      nativeBuildInputs = [pkgs.cargo];
      cargoVendorDir = craneLib.vendorCargoDeps {cargoLock = "${src}/Cargo.lock";};
    } ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp $cargoVendorDir/config.toml $CARGO_HOME/config.toml

      cargo metadata \
        -vv \
        --format-version=1 \
        --frozen --offline --locked \
        --manifest-path="${src}/Cargo.toml" \
        --filter-platform="${pkgs.stdenv.hostPlatform.rust.rustcTarget}" \
        > $out
    '';

  # Run `cargo tree` on a crate or workspace in `src`.
  cargoTree = {
    pkgs,
    src,
    name,
  }:
    pkgs.runCommandLocal "${name}.cargo-tree" {
      nativeBuildInputs = [pkgs.cargo];
      cargoVendorDir = craneLib.vendorCargoDeps {cargoLock = "${src}/Cargo.lock";};
    } ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp $cargoVendorDir/config.toml $CARGO_HOME/config.toml

      cargo tree \
        -vv \
        --frozen --offline --locked \
        --manifest-path="${src}/Cargo.toml" \
        --target="${pkgs.stdenv.hostPlatform.rust.rustcTarget}" \
        --edges=normal,build,features \
        > $out
    '';

  # Run `cargo build --unit-graph` on a crate or workspace in `src`.
  cargoUnitGraph = {
    pkgs,
    src,
    name,
  }:
    pkgs.runCommandLocal "${name}.cargo-unit-graph.json" {
      nativeBuildInputs = [pkgs.cargo];
      cargoVendorDir = craneLib.vendorCargoDeps {cargoLock = "${src}/Cargo.lock";};
    } ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp $cargoVendorDir/config.toml $CARGO_HOME/config.toml

      # --target=aarch64-unknown-linux-gnu
      cargo build \
        -vv \
        --frozen --offline --locked \
        --manifest-path="${src}/Cargo.toml" \
        --target="${pkgs.stdenv.hostPlatform.rust.rustcTarget}" \
        --package=fd-find \
        --bin=fd \
        -Z unstable-options \
        --unit-graph \
        > $out
    '';

  assertJsonDrvEq = {
    name ? "assert",
    json1,
    jq1 ? ".",
    json2,
    jq2 ? ".",
  }: let
    toJsonDrv = json:
      if isDerivation json
      then json
      else toJSON json;
  in
    pkgs.runCommandLocal "${name}-assert" {
      nativeBuildInputs = [pkgs.diffutils pkgs.jq];
      json1 = toJsonDrv json1;
      json2 = toJsonDrv json2;
      passAsFile =
        (optional (!isDerivation json1) "json1")
        ++ (optional (!isDerivation json2) "json2");
      jq1 = jq1;
      jq2 = jq2;
    } ''
      [[ -n "$json1Path" ]] && export json1=$json1Path
      [[ -n "$json2Path" ]] && export json2=$json2Path

      {
        diff -u --color=always \
          <(jq -S "$jq1" "$json1") \
          <(jq -S "$jq2" "$json2")
      } || {
        echo "json1 != json2."
        echo ""
        echo "json1 path: '$json1'"
        echo "json2 path: '$json2'"
        echo "jq1 selector: '$jq1'"
        echo "jq2 selector: '$jq2'"
        echo ""
        echo "retry locally with:"
        echo ""
        echo "\$ diff -u --color=always <(jq -S '$jq1' '$json1') <(jq -S '$jq2' '$json2')"
        echo ""
        exit 1
      }

      touch $out
    '';

  mkSmoketest = {
    src,
    name ? baseNameOf src,
    pkg-name ? name,
  }:
    (src: rec {
      metadata = cargoMetadata {inherit pkgs name src;};
      tree = cargoTree {inherit pkgs name src;};
      unitGraph = cargoUnitGraph {inherit pkgs name src;};
      workspacePkgManifests = mkWorkspacePkgManifests {src = src;};
      diffPkgManifest = assertJsonDrvEq {
        name = "${name}-${pkg-name}";
        json1 = metadata;
        jq1 = ''.packages[] | select(.name == "${pkg-name}")'';
        json2 = workspacePkgManifests;
        jq2 = ''."${pkg-name}"'';
      };
      diffPkgManifests = assertJsonDrvEq {
        name = "${name}";
        json1 = metadata;
        jq1 = ''.packages | map(select(.source == null) | { (.name): . }) | add'';
        json2 = workspacePkgManifests;
        jq2 = ''.'';
      };
      # workspaceManifest = mkWorkspaceInheritableManifest {
      #   lockVersion = 3;
      #   cargoToml = fromTOML (readFile (src + "/Cargo.toml"));
      # };
    }) "${src}"; # hack to make evaluation and derivation use same dir
  # })
  # src;

  # `builtins.dirOf` but it `throw`s if `dirPath` has no parent directory. It
  # also normalizes the output of `dirOf` so `dirOf "foo" == ""` and not "."
  # NOTE: only works for relative paths atm.
  strictDirOf = p:
    if p == "" || p == "."
    then throw "nocargo: dependency path must not leave workspace directory"
    else let
      parent = dirOf p;
    in
      if parent == "."
      then ""
      else parent;

  # "canonicalize" the path `${pkgDirRelPath}/${depRelPath}` so it doesn't
  # contain any "." or ".." segments.
  #
  # `pkgDirRelPath` is a relative path to a workspace crate dir. In this fn we
  # assume it's already normalized.
  #
  # `depRelPath` is a relative path from one workspace crate dir (the dependent)
  # to another workspace crate dir (the dependency).
  canonicalizeDepPath = pkgDirRelPath: depRelPath:
    removePrefix "/"
    (foldl' (
        acc: pathSegment:
        # matched "/" are included in the split... just ignore these
        #                                 vv              v
        # noop path segments like the "asd//dfdf" or "foo/./bar" are also
        # skipped over
          if !isString pathSegment || pathSegment == "" || pathSegment == "."
          then acc
          else if pathSegment == ".."
          then (strictDirOf acc)
          else (acc + "/" + pathSegment)
      )
      pkgDirRelPath
      (builtins.split "/" depRelPath));

  # A parsed dependency from a Cargo.toml manifest.
  #
  # See: <https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html>
  # See: <https://github.com/rust-lang/cargo/blob/0.78.0/src/cargo/core/dependency.rs#L55>
  #
  # ex manifest dependencies:
  #
  # ```toml
  # # Cargo.toml
  # tokio = "1.0"
  # anyhow = { workspace = true }
  # clap_complete = { version = "4.4.9", optional = true }
  # clap = { version = "4.4.13", features = [
  #   "suggestions", "color", "wrap_help", "cargo", "derive"
  # ] }
  # ```
  mkManifestDependency = {
    lockVersion,
    # `null` if this is a single crate package with no workspace.
    # otherwise, this is the _unparsed_ workspace Cargo.toml [workspace]
    # section. We inherit fields from this if this dep includes a
    # `workspace = true` field.
    workspaceToml,
    # Dir of the cargo workspace (or root crate).
    workspaceDir,
    # Parent dir of the Cargo.toml manifest that depends on this dependency.
    # This path is relative to the workspace directory, `workspaceDir`.
    pkgDirRelPath,
    # An optional "cfg(...)" target specifier.
    target,
    # The dependency kind ("normal", "dev", "build").
    kind,
  }: name: dep: let
    inheritsWorkspace =
      if dep ? workspace
      then assert assertMsg dep.workspace "nocargo: `workspace = false` is not allowed"; true
      else false;

    workspaceDep =
      if inheritsWorkspace
      then workspaceToml.dependencies.${name}
      # or throw "nocargo: missing required workspace dependency: ${name}"
      else null;

    # If this is a path dependency on another workspace crate, then this is the
    # path to that crate dir. Else null.
    depPath =
      if inheritsWorkspace
      then
        if workspaceDep ? path
        then (workspaceDir + "/${workspaceDep.path}")
        else null
      else if dep ? path
      then (workspaceDir + "/" + (canonicalizeDepPath pkgDirRelPath "${dep.path}"))
      else null;
  in
    {
      name = name;
      target = target;

      optional = dep.optional or false;

      # TODO(phlip9): dedup?
      features = (workspaceDep.features or []) ++ (dep.features or []);

      kind =
        if kind == "normal"
        # use `null` for normal deps to match `cargo metadata` output
        then null
        else kind;

      # The required semver version. ex: `^0.1`, `*`, `=3.0.4`, ...
      req = let
        version =
          # The dep body can be just a version string, ex: `tokio = "1.0"`.
          if isString dep
          then dep
          else if dep ? version
          then dep.version
          else if inheritsWorkspace
          then
            if isString workspaceDep
            then workspaceDep
            else workspaceDep.version or null
          else null;

        # ex: "1.0.34" is a 'bare' semver that should be translated to "^1.0.34"
        firstChar = substring 0 1 version;
        isBareSemver = (match "[[:digit:]]" firstChar) != null;
      in
        # For path or git dependencies, `version` can be omitted.
        if version == null
        then null
        else if isBareSemver
        then "^${version}"
        else version;

      # It's `default-features` in Cargo.toml, but `default_features` in index and in pkg info.
      # Name here is `uses_default_features` to match `cargo metadata` output.
      # See: <https://github.com/rust-lang/cargo/blob/07253b7ea640e8466408790bb6cad4440eb9531f/src/cargo/util/toml/mod.rs#L1860>
      uses_default_features =
        # warnIf (dep ? default_features || workspaceDep ? default_features) "Ignoring `default_features`. Do you mean `default-features`?"
        if !inheritsWorkspace
        then dep.default-features or true
        else let
          wdepDef = workspaceDep.default-features or true;
        in
          # If the workspace dependency either doesn't set `default-features` or
          # sets it to `true`, then that takes precedence over any member
          # dependencies due to feature unification.
          # TODO(phlip9): cargo warns if the member's `default-features == false`.
          if !(dep ? default-features)
          then wdepDef
          else if !wdepDef
          then dep.default-features
          else true;

      # See `sanitizeDep`
      rename = let
        pkg =
          if inheritsWorkspace
          then workspaceDep.package or null
          else dep.package or null;
      in
        if pkg != null
        then replaceStrings ["-"] ["_"] name
        else null;

      # This is used for dependency resolving inside Cargo.lock.
      source = let
        sourceDep =
          if inheritsWorkspace
          then workspaceDep
          else dep;
      in
        if sourceDep ? registry
        then throw "Dependency with `registry` is not supported. Use `registry-index` with explicit URL instead."
        else if sourceDep ? registry-index
        then "registry+${sourceDep.registry-index}"
        else if sourceDep ? git
        then
          # For v1 and v2, git-branch URLs are encoded as "git+url" with no query parameters.
          if sourceDep ? branch && lockVersion >= 3
          then "git+${sourceDep.git}?branch=${sourceDep.branch}"
          else if sourceDep ? tag
          then "git+${sourceDep.git}?tag=${sourceDep.tag}"
          else if sourceDep ? rev
          then "git+${sourceDep.git}?rev=${sourceDep.rev}"
          else "git+${sourceDep.git}"
        else if sourceDep ? path
        then
          # Local crates are mark with `null` source.
          null
        else
          # Default to use crates.io registry.
          # N.B. This is necessary and must not be `null`, or it will be indinstinguishable
          # with local crates or crates from other registries.
          "registry+https://github.com/rust-lang/crates.io-index";

      registry = null;
      # package = v.package or name;
    }
    # only included for path dependencies on other workspace crates
    // optionalAttrs (depPath != null) {path = depPath;};

  # inferredTargetsFromSubdir :: Path -> String -> List({ name: String, path: String })
  #
  # Search for automatic inferred cargo targets in a subdirectory. Effectively
  # the globs: `$src/$dir/*.rs` and `$src/$dir/*/main.rs`.
  inferredTargetsFromSubdir = src: dir: let
    subdirPath = src + "/${dir}";
  in
    if !pathExists subdirPath
    then []
    else
      foldlAttrs (
        acc: name: kind: let
          # ex: src/bin/mybin.rs
          topLevel = "${dir}/${name}";
          isTopLevelTarget = kind == "regular" && hasSuffix ".rs" name;
          topLevelTarget = {
            name = removeSuffix ".rs" name;
            path = topLevel;
          };

          # ex: src/bin/mybin/main.rs
          subdirMain = "${dir}/${name}/main.rs";
          isSubdirTarget = kind == "directory" && (pathExists (src + "/${subdirMain}"));
          subdirTarget = {
            name = name;
            path = subdirMain;
          };
        in
          if isTopLevelTarget
          then acc ++ [topLevelTarget]
          else if isSubdirTarget
          then acc ++ [subdirTarget]
          else acc
      ) [] (readDir subdirPath);

  # inferredFileTarget :: Path -> String -> String -> List({ name: String, path: String })
  inferredFileTarget = src: name: filepath:
    optional (pathExists (src + "/${filepath}")) {
      name = name;
      path = filepath;
    };

  # Infer the standard cargo package targets for a given target kind.
  #
  # See: <https://doc.rust-lang.org/cargo/guide/project-layout.html#package-layout>
  inferredKindTargets = src: name: kind:
    if kind == "lib"
    then inferredFileTarget src name "src/lib.rs"
    else if kind == "custom-build"
    then inferredFileTarget src "build-script-build" "build.rs"
    else if kind == "bin"
    then (inferredFileTarget src name "src/main.rs") ++ (inferredTargetsFromSubdir src "src/bin")
    else if kind == "test"
    then inferredTargetsFromSubdir src "tests"
    else if kind == "example"
    then inferredTargetsFromSubdir src "examples"
    else if kind == "bench"
    then inferredTargetsFromSubdir src "benches"
    else throw "nocargo: unrecognized crate target kind: ${kind}";

  # Default target settings for each target kind.
  pkgTargetDefaults = {
    lib = {
      doc = true;
      doctest = true;
      test = true;
      crate_types = ["lib"];
    };
    bin = {
      doc = true;
      doctest = false;
      test = true;
      crate_types = ["bin"];
    };
    custom-build = {
      doc = false;
      doctest = false;
      test = false;
      crate_types = ["bin"];
    };
    example = {
      doc = false;
      doctest = false;
      test = false;
      crate_types = ["bin"];
    };
    test = {
      doc = false;
      doctest = false;
      test = true;
      crate_types = ["bin"];
    };
    bench = {
      doc = false;
      doctest = false;
      test = false;
      crate_types = ["bin"];
    };
  };

  # "deserialize" a full package target spec from a partial `tomlTarget`. This
  # involves filling in missing values with defaults and making the target file
  # path absolute.
  deserializeTomlPkgTarget = {
    src,
    edition,
    name,
    kind,
    tomlTarget,
  }: let
    default = pkgTargetDefaults.${kind};
    # tomlTargetPath = tomlTarget.path or throw "nocargo: missing path for cargo target: (${kind})"
  in
    {
      kind = [kind];

      # target name is required for all target kinds except `lib`
      name =
        if kind != "lib"
        then tomlTarget.name
        else tomlTarget.name or name;
      src_path = mapNullable (path: src + "/${path}") (tomlTarget.path or null);

      crate_types =
        if kind == "lib" && (tomlTarget.proc-macro or false)
        then ["proc-macro"]
        else tomlTarget.crate-types or tomlTarget.crate_types or default.crate_types;

      edition = tomlTarget.edition or edition;
      doc = tomlTarget.doc or default.doc;
      doctest = tomlTarget.doctest or default.doctest;
      test = tomlTarget.test or default.test;
    }
    // optionalAttrs (tomlTarget ? required-features) {
      # TODO(phlip9): check subset of available features
      required-features = tomlTarget.required-features;
    };

  # Make the full package target set for a specific target kind.
  mkPkgKindTargets = {
    src,
    edition,
    name,
    kind,
    autodiscover,
    tomlTargets,
  }: let
    # Automatically inferred targets for this target kind.
    # ex: src/lib.rs, src/main.rs, src/bin/mybin.rs, etc...
    inferredTargets =
      if autodiscover
      then inferredKindTargets src name kind
      else [];

    # TODO(phlip9): optimize? doing a lot of O(N) list searching here...

    split =
      # short circuit for common case of no toml-specified targets
      if tomlTargets == null || tomlTargets == []
      then {
        right = inferredTargets;
        wrong = [];
      }
      else if kind == "lib"
      then {
        right = [];
        wrong = inferredTargets;
      }
      else
        # otherwise partition inferred targets into...
        partition (
          inferredTarget:
            all (
              tomlTarget:
                (inferredTarget.name != (tomlTarget.name or null)) && (inferredTarget.path != (tomlTarget.path or null))
            )
            tomlTargets
        )
        inferredTargets;

    # ...inferred targets that have no Cargo.toml targets touching them. These
    # just get passed through.
    remainingInferredTargets = split.right;
    # ...and inferred targets that have corresponding Cargo.toml targets and
    # need to be merged with them.
    toMergeInferredTargets = split.wrong;

    cleanedRemainingInferredTargets =
      map (tomlTarget: deserializeTomlPkgTarget {inherit src edition name kind tomlTarget;})
      remainingInferredTargets;

    cleanedTomlTargets = map (
      tomlTarget: let
        # Find any matching inferred target with the same name or path.
        inferredTarget =
          # lib targets need some special handling...
          if kind == "lib"
          then
            if length inferredTargets == 0
            then {name = name;}
            else elemAt inferredTargets 0
          else
            assert assertMsg (tomlTarget ? name || tomlTarget ? path) "nocargo: cargo target must have a name or path";
              findFirst (
                inferred: inferred.name == (tomlTarget.name or null) || inferred.path == (tomlTarget.path or null)
              )
              {}
              toMergeInferredTargets;
      in
        deserializeTomlPkgTarget {
          inherit src edition name kind;
          tomlTarget = inferredTarget // tomlTarget;
        }
    ) (orElse tomlTargets []);
  in
    cleanedRemainingInferredTargets ++ cleanedTomlTargets;

  # Collect package targets (lib, bins, examples, tests, benches) from the
  # package's directory layout.
  #
  # See: <https://doc.rust-lang.org/cargo/reference/cargo-targets.html#target-auto-discovery>
  mkPkgTargets = {
    src,
    edition,
    cargoToml,
  }: let
    # kinds = ["lib" "bin" "custom-build" "test" "example" "bench"];
    name = cargoToml.package.name;

    tomlTargetLib =
      if cargoToml ? lib
      then [cargoToml.lib]
      else [];
  in
    # Note: the list ordering is important. We want to match `cargo metadata`'s
    # output ordering: [lib bin example test bench build].
    concatLists [
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "lib";
        autodiscover = true;
        tomlTargets = tomlTargetLib;
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "bin";
        autodiscover = cargoToml.autobins or true;
        tomlTargets = cargoToml.bin or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "example";
        autodiscover = cargoToml.autoexamples or true;
        tomlTargets = cargoToml.example or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "test";
        autodiscover = cargoToml.autotests or true;
        tomlTargets = cargoToml.test or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "bench";
        autodiscover = cargoToml.autobenches or true;
        tomlTargets = cargoToml.bench or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "custom-build";
        # this looks weird, but `build` can be missing (enable autodiscover) a
        # boolean (maybe autodiscover), or a string path (disable autodiscover).
        autodiscover = (cargoToml.build or true) == true;
        tomlTargets = optional (cargoToml ? build && isString cargoToml.build) {
          name = "build-script-build";
          path = cargoToml.build;
        };
      })
    ];

  # Parse a package manifest (metadata) for a single package's Cargo.toml inside
  # the cargo workspace directory.
  #
  # See: <https://doc.rust-lang.org/cargo/reference/manifest.html>
  mkPkgManifest = {
    lockVersion,
    src,
    # [workspace] section in root Cargo.toml, or null if nonexistant.
    workspaceToml,
    # Dir of the cargo workspace (or root crate).
    workspaceDir,
    # package's Cargo.toml.
    cargoToml,
    # package's directory. Contains the Cargo.toml file. This path is relative
    # to the workspace directory.
    pkgDirRelPath,
  }: let
    collectTargetDeps = target: {
      dependencies ? {},
      dev-dependencies ? {},
      build-dependencies ? {},
      ...
    }: let
      transDeps = kind: deps:
        mapAttrsToList
        (mkManifestDependency {inherit lockVersion workspaceToml workspaceDir pkgDirRelPath target kind;})
        deps;

      deps = transDeps "normal" dependencies;
      devDeps = transDeps "dev" dev-dependencies;
      buildDeps = transDeps "build" build-dependencies;
    in
      concatLists [deps devDeps buildDeps];

    # Collect and flatten all direct dependencies of this crate into a list.
    dependencies =
      # standard [dependencies], [dev-dependencies], and [build-dependencies]
      (collectTargetDeps null cargoToml)
      ++
      # dependencies with `target.'cfg(...)'` constraints.
      concatLists (mapAttrsToList collectTargetDeps (cargoToml.target or {}));

    # Build the [features] mapping. Also adds the "dep:<crate>" pseudo-features
    # for optional dependencies.
    features = let
      maybeAddOptionalFeature = feats: dep:
        if !dep.optional
        then feats
        else let
          name =
            if dep.rename != null
            then dep.rename
            else dep.name;
        in
          feats // {${name} = ["dep:${name}"];};
    in
      foldl' maybeAddOptionalFeature (cargoToml.features or {}) dependencies;

    package = cargoToml.package;
    workspacePackage = workspaceToml.package;

    # TODO(phlip9): inherit workspace lints?

    # Try to inherit from the workspace if `cargoToml.${name}.workspace == true`.
    # Else fallback to default value `default`.
    tryInherit = propName: default:
      if !(package ? ${propName})
      then default # missing property, use default
      else let
        prop = package.${propName};
      in
        if prop ? workspace
        then
          # inherit from workspace
          assert (assertMsg prop.workspace "nocargo: `${propName}.workspace = false` is not allowed");
          assert (assertMsg (workspacePackage ? ${propName}) "nocargo: trying to inherit `${propName}` from workspace, but it doesn't exist in the workspace package");
            workspacePackage.${propName}
        else prop;

    # cargo defaults to "2015" if missing, for backwards compat.
    edition = tryInherit "edition" "2015";
  in {
    # TODO(phlip9): this adds an extra copy of the whole crate dir to the
    # store... try only conditionally adding this?
    dependencies = dependencies;
    edition = edition;
    features = features;
    id = "${package.name} ${package.version} (path+file://" + src + ")";
    links = package.links or null;
    manifest_path = src + "/Cargo.toml";
    name = package.name;
    source = null;
    targets = mkPkgTargets {inherit src edition cargoToml;};

    # We can inherit the package version from the workspace
    version = tryInherit "version" (throw "nocargo: package manifest is missing the `version` field");

    #
    # Extra fields needed to match `cargo metadata` output.
    #

    default_run = package.default-run or null;
    metadata = package.metadata or null;

    # Fields we can inherit from the workspace Cargo.toml [workspace.package]
    authors = tryInherit "authors" [];
    categories = tryInherit "categories" [];
    description = tryInherit "description" null;
    documentation = tryInherit "documentation" null;
    homepage = tryInherit "homepage" null;
    keywords = tryInherit "keywords" [];
    license = tryInherit "license" null;
    # TODO(phlip9): if inherited from workspace, then it's relative to the
    #               workspace root.
    license_file = tryInherit "license-file" null;
    publish = tryInherit "publish" null;
    # TODO(phlip9): if inherited from workspace, then it's relative to the
    #               workspace root.
    readme = tryInherit "readme" null;
    repository = tryInherit "repository" null;
    rust_version = tryInherit "rust-version" null;
  };

  # Parse package manifests all local crates inside the workspace.
  mkWorkspacePkgManifests = {
    src ? throw "require package src",
    cargoToml ? fromTOML (readFile (src + "/Cargo.toml")),
    cargoLock ? fromTOML (readFile (src + "/Cargo.lock")),
  }: let
    # Collect workspace packages from workspace Cargo.toml.
    selected = flatten (map (glob: globMatchDir glob src) cargoToml.workspace.members);
    excluded = map sanitizeRelativePath (cargoToml.workspace.exclude or []);
    workspaceMemberPaths = subtractLists excluded selected;

    # We don't distinguish between v1 and v2. But v3 is different from both.
    lockVersion = toInt (cargoLock.version or 3);

    # The [workspace] section in the root Cargo.toml (or null if there is none).
    workspaceToml = cargoToml.workspace or null;
    workspaceDir = src;

    # Package manifests for local crates inside the workspace.
    workspacePkgManifests =
      listToAttrs
      (map (
          relativePath: let
            # Path to cargo workspace member's directory.
            memberSrc =
              if relativePath == ""
              then src
              else src + "/${relativePath}";

            memberCargoToml =
              if relativePath != ""
              then fromTOML (readFile (memberSrc + "/Cargo.toml"))
              else cargoToml;
            memberManifest = mkPkgManifest {
              inherit lockVersion workspaceToml workspaceDir;
              src = memberSrc;
              cargoToml = memberCargoToml;
              pkgDirRelPath = relativePath;
            };
          in {
            name = toPkgId memberCargoToml.package;
            value = memberManifest;
          }
        ) (
          if cargoToml ? workspace
          then workspaceMemberPaths
          else [""] # top-level crate
        ));
  in
    workspacePkgManifests;
  # resolveDepsFromLock
  #
  # gitSrcInfos = {}; # : Attrset PkgInfo
  # registries = {}; # : Attrset Registry
  #
  # getPkgInfo = {
  #   source ? null,
  #   name,
  #   version,
  #   ...
  # } @ args: let
  #   m = match "(registry|git)\\+([^#]*).*" source;
  #   kind = elemAt m 0;
  #   url = elemAt m 1;
  # in
  #   # Local crates have no `source`.
  #   if source == null
  #   then
  #     localSrcInfos.${toPkgId args}
  #     or (throw "Local crate is outside the workspace: ${toPkgId args}")
  #     // {isLocalPkg = true;}
  #   else if m == null
  #   then throw "Invalid source: ${source}"
  #   else if kind == "registry"
  #   then
  #     getPkgInfoFromIndex
  #     (registries.${url}
  #       or (throw "Registry `${url}` not found. Please define it in `extraRegistries`."))
  #     args
  #     // {inherit source;} # `source` is for crate id, which is used for overrides.
  #   else if kind == "git"
  #   then
  #     gitSrcInfos.${url}
  #     or (throw "Git source `${url}` not found. Please define it in `gitSrcs`.")
  #   else throw "Invalid source: ${source}";
in {
  # test Cargo.toml features
  features = mkSmoketest {
    src = ../features;
    pkg-name = "simple-features";
  };

  # test basic cargo workspace w/ internal deps
  workspace-inline = mkSmoketest {
    src = ../workspace-inline;
    pkg-name = "bar";
  };

  # test parsing cargo package targets with both explicit and autodiscovered
  # targets
  pkg-targets = mkSmoketest {src = ../pkg-targets;};

  # non-trivial binary crate (not workspace)
  fd = mkSmoketest {
    name = "fd";
    pkg-name = "fd-find";
    src = pkgs.fetchFromGitHub {
      owner = "sharkdp";
      repo = "fd";
      rev = "68fe31da3f5da5d8d5b997d8919dc97e6eafead5";
      hash = "sha256-WH2rZ5fOZFt5BTN8QNhpY18CFsr6Lt5zJGgBuB2GvS8=";
    };
  };

  # non-trivial binary crate (workspace)
  rage = mkSmoketest rec {
    name = "rage";
    src = pkgs.fetchFromGitHub {
      owner = "str4d";
      repo = name;
      rev = "v0.10.0";
      hash = "sha256-7PfNDFDuvQ9T3BeA15FuY1jAprGLsyglWXcNrZvtPAE=";
    };
  };

  # unit tests
  tests = let
    testCanonicalizeDepPath = let
      case = pkgDirRelPath: depPath: expected: {
        expr = canonicalizeDepPath pkgDirRelPath depPath;
        expected = expected;
      };

      cases = [
        (case "" "" "")
        (case "" "a" "a")
        (case "" "a/b" "a/b")
        (case "a" "" "a")
        (case "a" "b" "a/b")
        (case "a" "../b" "b")
        (case "a" "." "a")
        (case "a" "./" "a")
        (case "a" "./b" "a/b")
        (case "a" "./b/" "a/b")
        (case "a/b" "../../c" "c")
        # (case "" "../b" "<throws>")
        # (case "a" "../../b" "<throws>")
      ];
    in
      builtins.listToAttrs (builtins.genList (idx: {
        name = "testCanonicalizeDepPath${toString idx}";
        value = elemAt cases idx;
      }) (length cases));
  in
    runTests (
      testCanonicalizeDepPath
      # # uncomment to run specific tests
      # // {tests = ["test1"];}
    );
}
