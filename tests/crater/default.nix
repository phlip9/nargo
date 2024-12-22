{
  inputs,
  pkgs,
}: let
  lib = inputs.nixpkgs.lib;
  nocargo-lib = import ../../lib {inherit lib;};
  craneLib = inputs.crane.mkLib pkgs;

  inherit
    (builtins)
    all
    any
    attrValues
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
    toJSON
    ;
  inherit
    (lib)
    assertMsg
    findFirst
    flatten
    foldlAttrs
    hasPrefix
    hasSuffix
    isDerivation
    isString
    mapAttrsToList
    mapNullable
    optional
    optionals
    optionalAttrs
    removePrefix
    removeSuffix
    replaceStrings
    runTests
    subtractLists
    ;
  inherit (nocargo-lib.glob) globMatchDir;
  inherit (nocargo-lib.pkg-info) mkPkgInfoFromCargoToml;
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
    cargoVendorDir,
    name,
  }:
    pkgs.runCommandLocal "${name}.cargo-metadata.json" {
      inherit cargoVendorDir;
      nativeBuildInputs = [pkgs.cargo];
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
        > $out
    '';
  # TODO(phlip9): add ability to eval with platform filter for faster eval?
  # --filter-platform="${pkgs.stdenv.hostPlatform.rust.rustcTarget}" \

  # Run `cargo tree` on a crate or workspace in `src`.
  cargoTree = {
    pkgs,
    src,
    cargoVendorDir,
    name,
  }:
    pkgs.runCommandLocal "${name}.cargo-tree" {
      inherit cargoVendorDir;
      nativeBuildInputs = [pkgs.cargo];
    } ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp $cargoVendorDir/config.toml $CARGO_HOME/config.toml

      cargo tree \
        -vv \
        --frozen --offline --locked \
        --manifest-path="${src}/Cargo.toml" \
        --edges=normal,build,features \
        > $out
    '';
  # --target="${pkgs.stdenv.hostPlatform.rust.rustcTarget}" \

  # Run `cargo build --unit-graph` on a crate or workspace in `src`.
  cargoUnitGraph = {
    pkgs,
    src,
    cargoVendorDir,
    name,
  }:
    pkgs.runCommandLocal "${name}.cargo-unit-graph.json" {
      inherit cargoVendorDir;
      nativeBuildInputs = [pkgs.cargo];
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
        diff --unified=10 --color=always \
          <(jq -S -L "${./jq-lib}" "$jq1" "$json1") \
          <(jq -S -L "${./jq-lib}" "$jq2" "$json2")
      } || {
        echo "json1 != json2"
        echo ""
        echo "json1 path: '$json1'"
        echo "json2 path: '$json2'"
        echo "jq1 selector: '$jq1'"
        echo "jq2 selector: '$jq2'"
        echo ""
        echo "retry locally with:"
        echo ""
        echo "\$ diff --unified=10 --color=always" '\'
        echo "     <(jq -S -L ./tests/crater/jq-lib '$jq1' '$json1')" '\'
        echo "     <(jq -S -L ./tests/crater/jq-lib '$jq2' '$json2')"
        echo ""
        exit 1
      }

      touch $out
    '';

  stripNewLines = str: replaceStrings ["\n"] [" "] str;

  mkSmoketest = {
    src,
    cargoToml ? fromTOML (readFile (src + "/Cargo.toml")),
    cargoLock ? fromTOML (readFile (src + "/Cargo.lock")),
    name ? baseNameOf src,
    pkg-name ? name,
  }:
    (src: rec {
      cargoVendorDir = craneLib.vendorCargoDeps {cargoLockParsed = cargoLock;};

      metadata = cargoMetadata {inherit cargoVendorDir name pkgs src;};
      tree = cargoTree {inherit cargoVendorDir name pkgs src;};
      unitGraph = cargoUnitGraph {inherit cargoVendorDir name pkgs src;};

      workspacePkgManifests = mkWorkspacePkgManifests {inherit src cargoToml cargoLock;};
      workspacePkgInfos = mkWorkspacePkgInfos {inherit src cargoToml;};
      workspacePkgInfos2 = map mkPkgInfoFromPkgManifest workspacePkgManifests;

      # diff a specific package's `cargo metadata` with our `mkPkgManifest`
      diffPkgManifest = assertJsonDrvEq {
        name = "${name}-${pkg-name}";
        json1 = metadata;
        jq1 = stripNewLines ''
          import "lib" as lib;
          .packages[] | select(.name == "${pkg-name}") | lib::cleanPkgManifest
        '';
        json2 = workspacePkgManifests;
        jq2 = stripNewLines ''
          import "lib" as lib;
          . | select(.name == "${pkg-name}") | lib::cleanPkgManifest
        '';
      };

      # diff all workspace package `cargo metadata` with our
      # `mkWorkspacePkgManifests`.
      diffPkgManifests = assertJsonDrvEq {
        name = "${name}";
        json1 = metadata;
        jq1 = stripNewLines ''
          import "lib" as lib;
          .packages | lib::cleanCargoMetadataPkgs
        '';
        json2 = workspacePkgManifests;
        jq2 = stripNewLines ''
          import "lib" as lib;
          . | lib::cleanNocargoMetadataPkgs
        '';
      };

      # diff all workspace `PkgInfo` derived using existing nocargo method and
      # `PkgManifest` -> `PkgInfo` method.
      diffPkgInfos = assertJsonDrvEq {
        name = "${name}-pkginfos";
        json1 = workspacePkgInfos;
        json2 = workspacePkgInfos2;
      };
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

  canonicalAppendPath = dir: relPath:
    if relPath == ""
    then dir
    else dir + "/${relPath}";

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
        # then (workspaceDir + "/${workspaceDep.path}")
        then (canonicalAppendPath workspaceDir workspaceDep.path)
        else null
      else if dep ? path
      # then (workspaceDir + ("/" + (canonicalizeDepPath pkgDirRelPath "${dep.path}")))
      then (canonicalAppendPath workspaceDir (canonicalizeDepPath pkgDirRelPath dep.path))
      else null;
  in
    {
      name = workspaceDep.package or dep.package or name;
      target = target;

      optional = dep.optional or false;

      # TODO(phlip9): dedup?
      features = (workspaceDep.features or []) ++ (dep.features or []);

      kind =
        if kind == "normal"
        # use `null` for normal deps to match `cargo metadata` output
        then null
        else kind;

      rename =
        if (workspaceDep.package or dep.package or null) != null
        then name
        else null;

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
            else workspaceDep.version or "*"
          else "*";

        # ex: "1.0.34" is a 'bare' semver that should be translated to "^1.0.34"
        firstChar = substring 0 1 version;
        isBareSemver = (match "[[:digit:]]" firstChar) != null;
      in
        if isBareSemver
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
          notDotfile = !(hasPrefix "." name);

          # ex: src/bin/mybin.rs
          topLevel = "${dir}/${name}";
          isTopLevelTarget = kind == "regular" && hasSuffix ".rs" name && notDotfile;
          topLevelTarget = {
            name = removeSuffix ".rs" name;
            path = topLevel;
          };

          # ex: src/bin/mybin/main.rs
          subdirMain = "${dir}/${name}/main.rs";
          isSubdirTarget = kind == "directory" && notDotfile && pathExists (src + "/${subdirMain}");
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
    package = cargoToml.package;
    name = package.name;

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
        autodiscover = package.autobins or true;
        tomlTargets = cargoToml.bin or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "example";
        autodiscover = package.autoexamples or true;
        tomlTargets = cargoToml.example or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "test";
        autodiscover = package.autotests or true;
        tomlTargets = cargoToml.test or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "bench";
        autodiscover = package.autobenches or true;
        tomlTargets = cargoToml.bench or [];
      })
      (mkPkgKindTargets {
        inherit src edition name;
        kind = "custom-build";
        # this looks weird, but `build` can be missing (enable autodiscover) a
        # boolean (maybe autodiscover), or a string path (disable autodiscover).
        autodiscover = (package.build or true) == true;
        tomlTargets = optional (package ? build && isString package.build) {
          name = "build-script-build";
          path = package.build;
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
    # TODO(phlip9): validate feature names: <https://github.com/rust-lang/cargo/blob/rust-1.78.0/crates/cargo-util-schemas/src/restricted_names.rs#L195>
    features = let
      rawFeatures = cargoToml.features or {};

      # explicitDepFeatures :: Set<DepName>
      #
      # Find all the "dep:<name>" features already mentioned in the `[feature]`
      # section.
      explicitDepFeatures = foldl' (
        acc: featureValues:
          foldl' (
            acc': featureValue:
              if hasPrefix "dep:" featureValue
              then acc' // {${substring 4 (-1) featureValue} = null;}
              else acc'
          )
          acc
          featureValues
      ) {} (attrValues rawFeatures);

      # Add all `{ optional = true }` features as `dep:<name>` features, except
      # those that were already explicitly mentioned in the crate's [feature]
      # section.
      maybeAddOptionalFeature = acc: dep:
        if !dep.optional
        then acc
        else let
          name =
            if dep.rename != null
            then dep.rename
            else dep.name;
        in
          if ! (explicitDepFeatures ? ${name})
          then acc // {${name} = ["dep:${name}"];}
          else acc;
    in
      foldl' maybeAddOptionalFeature rawFeatures dependencies;

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

    # readme  unset  => look for README.md, README.txt, or README in pkg dir
    # readme  false  => null
    # readme  true   => assume README.md
    # readme  "..."  => assume "..."
    resolvePkgReadme = optReadmeStringOrBool:
      if optReadmeStringOrBool == null
      then
        foldl' (
          acc: file:
            if acc != null
            then acc
            else if pathExists (src + "/${pkgDirRelPath}/${file}")
            then file
            else null
        )
        null ["README.md" "README.txt" "README"]
      else if isString optReadmeStringOrBool
      then optReadmeStringOrBool
      else if optReadmeStringOrBool == true
      then "README.md"
      else null;

    # cargo defaults to "2015" if missing, for backwards compat.
    edition = tryInherit "edition" "2015";

    # We can inherit the package version from the workspace
    version = tryInherit "version" (throw "nocargo: package manifest is missing the `version` field");
  in {
    # TODO(phlip9): this adds an extra copy of the whole crate dir to the
    # store... try only conditionally adding this?
    dependencies = dependencies;
    edition = edition;
    features = features;
    id = "${package.name} ${version} (path+file://" + src + ")";
    links = package.links or null;
    manifest_path = src + "/Cargo.toml";
    name = package.name;
    source = null;
    targets = mkPkgTargets {inherit src edition cargoToml;};
    version = version;

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
    # TODO(phlip9): not sure how this works...
    publish = let
      raw = tryInherit "publish" null;
    in
      if raw == false
      then []
      else raw;
    readme = resolvePkgReadme (tryInherit "readme" null);
    repository = tryInherit "repository" null;
    rust_version = tryInherit "rust-version" null;
  };

  # target :: deserializeTomlPkgTarget
  targetIsProcMacro = target:
    target.kind == ["lib"] && target.crate_types == ["proc-macro"];

  mkPkgInfoDepFromPkgManifestDep = dep:
    {
      default_features = dep.uses_default_features;
      features = dep.features;
      kind =
        if dep.kind == null
        then "normal"
        else dep.kind;
      name =
        if dep.rename != null
        then dep.rename
        else dep.name;
      optional = dep.optional;
      package = dep.name;
      req =
        if dep.req == "*"
        then null
        else if hasPrefix "^" dep.req
        then removePrefix "^" dep.req
        else dep.req;
      source = dep.source;
      target = dep.target;
    }
    // optionalAttrs (dep.rename != null) {
      rename = replaceStrings ["-"] ["_"] dep.rename;
    };

  # Create a nocargo `PkgInfo` from a `PkgManifest` (which closely matches the
  # cargo metadata output).
  mkPkgInfoFromPkgManifest = manifest: {
    name = manifest.name;
    version = manifest.version;
    links = manifest.links;
    src = dirOf manifest.manifest_path;
    features = manifest.features;
    dependencies = map mkPkgInfoDepFromPkgManifestDep manifest.dependencies;
    procMacro = any targetIsProcMacro manifest.targets;
  };

  # deserializeWorkspaceCargoTomls :: { src: Path, cargoToml: AttrSet }
  #   -> List<{ relativePath: String, src: Path, cargoToml: AttrSet }>
  #
  # From the workspace Cargo.toml, find all workspace members and deserialize
  # each member Cargo.toml.
  deserializeWorkspaceCargoTomls = {
    # The workspace source directory.
    src,
    # The deserialized workspace root Cargo.toml.
    cargoToml,
  }: let
    # Collect workspace packages from workspace Cargo.toml.
    selected = flatten (map (glob: globMatchDir glob src) cargoToml.workspace.members);
    excluded = map sanitizeRelativePath (cargoToml.workspace.exclude or []);
    workspaceMemberPaths = subtractLists (excluded ++ [""]) selected;

    workspacePkgPaths =
      optionals (cargoToml ? workspace) workspaceMemberPaths
      # top-level crate
      ++ optional (cargoToml ? package) "";
  in
    map (relativePath: let
      memberSrc =
        if relativePath == ""
        then src
        else src + "/${relativePath}";
    in {
      # The relative path to the workspace member directory, inside the workspace.
      relativePath = relativePath;

      # Path to cargo workspace member's directory.
      src = memberSrc;

      # The parsed workspace member's Cargo.toml manifest file
      cargoToml =
        if relativePath != ""
        then fromTOML (readFile (memberSrc + "/Cargo.toml"))
        else cargoToml;
    })
    workspacePkgPaths;

  # Parse package manifests from all local crates inside the workspace.
  mkWorkspacePkgManifests = {
    src ? throw "require package src",
    cargoToml ? fromTOML (readFile (src + "/Cargo.toml")),
    cargoLock ? fromTOML (readFile (src + "/Cargo.lock")),
  }: let
    # We don't distinguish between v1 and v2. But v3+ is different from both.
    lockVersion = cargoLock.version or 2;

    # The [workspace] section in the root Cargo.toml (or null if there is none).
    workspaceToml = cargoToml.workspace or null;
    workspaceDir = src;

    workspaceCargoTomls = deserializeWorkspaceCargoTomls {inherit src cargoToml;};
  in
    # Package manifests for local crates inside the workspace.
    map (member:
      mkPkgManifest {
        inherit lockVersion workspaceToml workspaceDir;
        src = member.src;
        cargoToml = member.cargoToml;
        pkgDirRelPath = member.relativePath;
      })
    workspaceCargoTomls;

  # Parse package infos from all local crates inside the workspace.
  mkWorkspacePkgInfos = {
    src ? throw "require package src",
    cargoToml ? fromTOML (readFile (src + "/Cargo.toml")),
  }:
    map
    (member: mkPkgInfoFromCargoToml member.cargoToml member.src)
    (deserializeWorkspaceCargoTomls {inherit src cargoToml;});
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

  # TODO(phlip9): unbreak crane w/ www.github.com registry
  # # package renames + v3 lock file
  # dependency-v3 = mkSmoketest {
  #   src = ../dependency-v3;
  #   pkg-name = "dependencies";
  # };

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

  # non-trivial binary crate (workspace)
  ripgrep = mkSmoketest {inherit (pkgs.ripgrep) name src;};

  # non-trivial
  hickory-dns = mkSmoketest {inherit (pkgs.trust-dns) name src;};

  # small crate
  cargo-hack = mkSmoketest {inherit (pkgs.cargo-hack) name src;};

  # non-trivial library (workspace)
  rand = mkSmoketest rec {
    name = "rand";
    src = let
      src' = pkgs.fetchFromGitHub {
        owner = "rust-random";
        repo = name;
        rev = "bf0301bfe6d2360e6c86a6c58273f7069f027691"; # 2024-04-27
        hash = "sha256-ahiydkkJHwUX13eiGh2aCRSofbxvevk22oKMgLMOl2g=";
      };
    in
      pkgs.runCommandLocal "rand-patched" {src_raw = src';} ''
        mkdir -p $out
        cp -r $src_raw/* $out/
        cp $src_raw/Cargo.lock.msrv $out/Cargo.lock
      '';
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
