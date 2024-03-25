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
    filter
    foldl'
    fromTOML
    match
    pathExists
    readDir
    readFile
    substring
    ;
  inherit
    (lib)
    flatten
    foldlAttrs
    hasSuffix
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
  }: let
    cargoLock = "${src}/Cargo.lock";
    cargoVendorDir = craneLib.vendorCargoDeps {inherit cargoLock;};
  in
    pkgs.runCommandLocal "${name}.cargo-metadata.json" {} ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp ${cargoVendorDir}/config.toml $CARGO_HOME/config.toml

      ${pkgs.cargo}/bin/cargo metadata \
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
  }: let
    cargoLock = "${src}/Cargo.lock";
    cargoVendorDir = craneLib.vendorCargoDeps {inherit cargoLock;};
  in
    pkgs.runCommandLocal "${name}.cargo-tree" {} ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp ${cargoVendorDir}/config.toml $CARGO_HOME/config.toml

      # --target=aarch64-unknown-linux-gnu
      ${pkgs.cargo}/bin/cargo tree \
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
  }: let
    cargoLock = "${src}/Cargo.lock";
    cargoVendorDir = craneLib.vendorCargoDeps {inherit cargoLock;};
  in
    pkgs.runCommandLocal "${name}.cargo-unit-graph.json" {} ''
      export CARGO_TARGET_DIR="$PWD/target"

      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp ${cargoVendorDir}/config.toml $CARGO_HOME/config.toml

      # --target=aarch64-unknown-linux-gnu
      ${pkgs.cargo}/bin/cargo build \
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
    kind,
    tomlTarget,
  }: let
    default = pkgTargetDefaults.${kind};
  in
    {
      kind = [kind];
      name = tomlTarget.name or null;
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

  mkPkgKindTargets = {
    source,
    edition,
    name,
    kind,
    autodiscover,
    tomlTargets,
  }: let
    inferred =
      if autodiscover
      then inferredKindTargets source name kind
      else [];

    inferredTargets =
      map (tomlTarget: deserializeTomlPkgTarget {inherit source edition kind tomlTarget;})
      inferred;

    # ignore inferred targets that have any Cargo.toml targets covering them
    remainingInferredTargets =
      filter (
        inferredTarget:
          all (
            tomlTarget:
              (inferredTarget.name != tomlTarget.name)
              && (inferredTarget.path != tomlTarget.path)
          )
      )
      inferredTargets;

    cleanedTomlTargets = map (
      tomlTarget: deserializeTomlPkgTarget {inherit source edition kind tomlTarget;}
    ) (orElse tomlTargets []);
  in
    if tomlTargets == null || tomlTargets == []
    then inferredTargets
    else cleanedTomlTargets ++ remainingInferredTargets;

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
    # Note: order is important
    # lib bin example test bench build
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
        autodiscover = false;
        tomlTargets = [
          {
            name = "build-script-build";
            path = cargoToml.bin or "build.rs";
          }
        ];
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
    transDeps = {
      target,
      kind,
      deps,
    }:
      mapAttrsToList
      (mkManifestDependency {inherit lockVersion target kind;})
      deps;

    collectTargetDeps = target: {
      dependencies ? {},
      dev-dependencies ? {},
      build-dependencies ? {},
      ...
    }: let
      deps = transDeps {
        inherit target;
        kind = "normal";
        deps = dependencies;
      };
      devDeps = transDeps {
        inherit target;
        kind = "dev";
        deps = dev-dependencies;
      };
      buildDeps = transDeps {
        inherit target;
        kind = "build";
        deps = build-dependencies;
      };
    in
      concatLists [deps devDeps buildDeps];

    dependencies = flatten [
      # standard [dependencies], [dev-dependencies], and [build-dependencies]
      (collectTargetDeps null cargoToml)
      # dependencies with `target.'cfg(...)'` constraints.
      (mapAttrsToList collectTargetDeps (cargoToml.target or {}))
    ];

    # Add the "dep:<crate>" pseudo-features for optional dependencies.
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
    id = "${package.name} ${package.version} (path+file://${source})";

    edition = edition;
    dependencies = dependencies;
    features = features;
    links = package.links or null;
    source = null;

    # targets = mkPkgTargets2 {inherit cargoToml source edition features;};
    targets = mkPkgTargets {inherit source edition cargoToml;};

    # procMacro = cargoToml.lib.proc-macro or false;

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

    manifest_path = "${source}/Cargo.toml";
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
  #
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

  mkSmoketest = {
    src,
    name ? baseNameOf src,
  }:
    (src: {
      metadata = cargoMetadata {inherit pkgs name src;};
      tree = cargoTree {inherit pkgs name src;};
      unitGraph = cargoUnitGraph {inherit pkgs name src;};
      workspacePkgManifests = mkWorkspacePkgManifests {src = src;};
    }) "${src}"; # hack to make evaluation and derivation use same dir
in {
  features = mkSmoketest {src = ../features;};

  workspace-inline = mkSmoketest {src = ../workspace-inline;};

  pkg-targets = mkSmoketest {src = ../pkg-targets;};

  # foo = inferredTargetsFromSubdir ../pkg-targets "src/bin";
  # bar = inferredTargetsFromPkgSrc (fromTOML (readFile ../pkg-targets/Cargo.toml)) ../pkg-targets;

  fd = mkSmoketest {
    name = "fd";
    src = pkgs.fetchFromGitHub {
      owner = "sharkdp";
      repo = "fd";
      rev = "68fe31da3f5da5d8d5b997d8919dc97e6eafead5";
      hash = "sha256-WH2rZ5fOZFt5BTN8QNhpY18CFsr6Lt5zJGgBuB2GvS8=";
    };
  };
}
