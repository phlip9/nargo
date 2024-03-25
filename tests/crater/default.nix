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
    foldl'
    fromTOML
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
    hasSuffix
    isDerivation
    isString
    listToAttrs
    mapAttrsToList
    mapNullable
    optional
    optionalAttrs
    removeSuffix
    replaceStrings
    subtractLists
    warnIf
    ;
  inherit (nocargo-lib.pkg-info) toPkgId;
  inherit (nocargo-lib.glob) globMatchDir;
  inherit (nocargo-lib.support) sanitizeRelativePath;

  # dbg = x: builtins.trace x x;
  # dbgJson = x: builtins.trace (builtins.toJSON x) x;

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
      diffPkgManifests = assertJsonDrvEq {
        name = "${name}-${pkg-name}";
        json1 = metadata;
        jq1 = ''.packages[] | select(.name == "${pkg-name}")'';
        json2 = workspacePkgManifests;
        jq2 = ''."${pkg-name}"'';
      };
    }) "${src}"; # hack to make evaluation and derivation use same dir

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
    # An optional "cfg(...)" target specifier.
    target,
    # The dependency kind (normal, dev, build)
    kind,
  }: name: dep: {
    name = name;
    target = target;
    features = dep.features or [];
    optional = dep.optional or false;

    kind =
      if kind == "normal"
      # use `null` for normal deps to match `cargo metadata` output
      then null
      else kind;

    # The required semver version. ex: `^0.1`, `*`, `=3.0.4`, ...
    req = let
      version =
        # The dep body can be just the version string, ex: `tokio = "1.0"`.
        if isString dep
        then dep
        else dep.version or null;
      firstChar = substring 0 1 version;
      # ex: "1.0.34" is a 'bare' semver that should be translated to "^1.0.34"
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
    uses_default_features =
      warnIf (dep ? default_features) "Ignoring `default_features`. Do you mean `default-features`?"
      (dep.default-features or true);

    # See `sanitizeDep`
    rename =
      if (dep.package or null) != null
      then replaceStrings ["-"] ["_"] name
      else null;

    # This is used for dependency resolving inside Cargo.lock.
    source =
      if dep ? registry
      then throw "Dependency with `registry` is not supported. Use `registry-index` with explicit URL instead."
      else if dep ? registry-index
      then "registry+${dep.registry-index}"
      else if dep ? git
      then
        # For v1 and v2, git-branch URLs are encoded as "git+url" with no query parameters.
        if dep ? branch && lockVersion >= 3
        then "git+${dep.git}?branch=${dep.branch}"
        else if dep ? tag
        then "git+${dep.git}?tag=${dep.tag}"
        else if dep ? rev
        then "git+${dep.git}?rev=${dep.rev}"
        else "git+${dep.git}"
      else if dep ? path
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
  };

  # inferredTargetsFromSubdir :: Path -> String -> List({ name: String, path: String })
  #
  # Search for automatic inferred cargo targets in a subdirectory. Effectively
  # the globs: `$source/$dir/*.rs` and `$source/$dir/*/main.rs`.
  inferredTargetsFromSubdir = source: dir: let
    subdirPath = source + "/${dir}";
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
          isSubdirTarget = kind == "directory" && (pathExists (source + "/${subdirMain}"));
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
  inferredFileTarget = source: name: filepath:
    optional (pathExists (source + "/" + filepath)) {
      name = name;
      path = filepath;
    };

  # Infer the standard cargo package targets for a given target kind.
  #
  # See: <https://doc.rust-lang.org/cargo/guide/project-layout.html#package-layout>
  inferredKindTargets = source: name: kind:
    if kind == "lib"
    then inferredFileTarget source name "src/lib.rs"
    else if kind == "custom-build"
    then inferredFileTarget source "build-script-build" "build.rs"
    else if kind == "bin"
    then (inferredFileTarget source name "src/main.rs") ++ (inferredTargetsFromSubdir source "src/bin")
    else if kind == "test"
    then inferredTargetsFromSubdir source "tests"
    else if kind == "example"
    then inferredTargetsFromSubdir source "examples"
    else if kind == "bench"
    then inferredTargetsFromSubdir source "benches"
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
    source,
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
      src_path = mapNullable (path: source + "/${path}") (tomlTarget.path or null);

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
      required_features = tomlTarget.required-features;
    };

  # Make the full package target set for a specific target kind.
  mkPkgKindTargets = {
    source,
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
      then inferredKindTargets source name kind
      else [];

    # TODO(phlip9): optimize? doing a lot of O(N) list searching here...

    split =
      # short circuit for common case of no toml-specified targets
      if tomlTargets == null || tomlTargets == []
      then {
        right = inferredTargets;
        wrong = [];
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
      map (tomlTarget: deserializeTomlPkgTarget {inherit source edition name kind tomlTarget;})
      remainingInferredTargets;

    cleanedTomlTargets = map (
      tomlTarget: let
        # Find any matching inferred target with the same name or path.
        inferredTarget = assert assertMsg (tomlTarget ? name || tomlTarget ? path) "nocargo: cargo target must have a name or path";
          findFirst (
            inferred: inferred.name == tomlTarget.name || inferred.path == tomlTarget.path
          )
          {}
          toMergeInferredTargets;
      in
        deserializeTomlPkgTarget {
          inherit source edition name kind;
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
    source,
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
        inherit source edition name;
        kind = "lib";
        autodiscover = true;
        tomlTargets = tomlTargetLib;
      })
      (mkPkgKindTargets {
        inherit source edition name;
        kind = "bin";
        autodiscover = cargoToml.autobins or true;
        tomlTargets = cargoToml.bin or [];
      })
      (mkPkgKindTargets {
        inherit source edition name;
        kind = "example";
        autodiscover = cargoToml.autoexamples or true;
        tomlTargets = cargoToml.example or [];
      })
      (mkPkgKindTargets {
        inherit source edition name;
        kind = "test";
        autodiscover = cargoToml.autotests or true;
        tomlTargets = cargoToml.test or [];
      })
      (mkPkgKindTargets {
        inherit source edition name;
        kind = "bench";
        autodiscover = cargoToml.autobenches or true;
        tomlTargets = cargoToml.bench or [];
      })
      (mkPkgKindTargets {
        inherit source edition name;
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
    cargoToml,
    source,
  }: let
    collectTargetDeps = target: {
      dependencies ? {},
      dev-dependencies ? {},
      build-dependencies ? {},
      ...
    }: let
      transDeps = kind: deps:
        mapAttrsToList (mkManifestDependency {inherit lockVersion target kind;}) deps;

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

    # cargo defaults to "2015" if missing, for backwards compat.
    edition = package.edition or "2015";

    package = cargoToml.package;
  in {
    name = package.name;
    version = package.version;
    id = "${package.name} ${package.version} (path+file://${src})";
    manifest_path = src + "/Cargo.toml";

    edition = edition;
    dependencies = dependencies;
    features = features;
    links = package.links or null;
    source = null;

    targets = mkPkgTargets {inherit source edition cargoToml;};

    # Extra fields needed to match `cargo metadata` output.
    authors = package.authors or [];
    categories = package.categories or [];
    default_run = package.default-run or null;
    description = package.description or null;
    documentation = package.documentation or null;
    homepage = package.homepage or null;
    keywords = package.keywords or [];
    license = package.license or null;
    license_file = package.license-file or null;
    metadata = package.metadata or null;
    publish = package.publish or null;
    readme = package.readme or null;
    repository = package.repository or null;
    rust_version = package.rust-version or null;
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
    lockVersion = cargoLock.version or 3;

    # Package manifests for local crates inside the workspace.
    workspacePkgManifests =
      listToAttrs
      (map (
          relativePath: let
            # Path to cargo workspace member's directory.
            memberSource =
              if relativePath == ""
              then src
              else src + "/${relativePath}";

            memberCargoToml = fromTOML (readFile (memberSource + "/Cargo.toml"));
            memberManifest = mkPkgManifest {
              inherit lockVersion;
              cargoToml = memberCargoToml;
              source = memberSource;
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
  features = mkSmoketest {
    src = ../features;
    pkg-name = "simple-features";
  };

  workspace-inline = mkSmoketest {
    src = ../workspace-inline;
    pkg-name = "bar";
  };

  pkg-targets = mkSmoketest {src = ../pkg-targets;};

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

  # foo = inferredTargetsFromSubdir ../pkg-targets "src/bin";
  # bar = inferredTargetsFromPkgSrc (fromTOML (readFile ../pkg-targets/Cargo.toml)) ../pkg-targets;
}
