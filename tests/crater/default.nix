{
  self,
  pkgs,
  inputs,
}: let
  lib = inputs.nixpkgs.lib;
  nocargo-lib = import ../../lib {inherit lib;};
  craneLib = inputs.crane.mkLib pkgs;

  inherit (builtins) concatLists elemAt foldl' match fromTOML readFile substring;
  inherit (nocargo-lib.pkg-info) getPkgInfoFromIndex toPkgId;
  inherit (nocargo-lib.glob) globMatchDir;
  inherit (nocargo-lib.support) sanitizeRelativePath;
  inherit
    (lib)
    flatten
    isString
    listToAttrs
    mapAttrsToList
    replaceStrings
    subtractLists
    warnIf
    ;

  # defaultRegistries = {
  #   "https://github.com/rust-lang/crates.io-index" =
  #     nocargo-lib.pkg-info.mkIndex
  #     pkgs.fetchurl
  #     inputs.registry-crates-io
  #     (import ../../crates-io-override {inherit lib pkgs;});
  # };

  # cargoToml = fromTOML (readFile "${src}/Cargo.toml");
  # pkgInfo = mkPkgInfoFromCargoToml cargoToml "<src>";

  # fd = nocargo-lib.mkRustPackageOrWorkspace {
  #   src = ;
  # };

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
        --package=fd-find \
        --edges=normal,build,features \
        > $out
    '';

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

  # dbg = x: builtins.trace x x;
  #
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

  # Metadata for a single package's Cargo.toml inside a cargo workspace.
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
    featuresWithOptionalDepFeatuers = let
      maybeAddOptionalFeature = features: dep:
        if !dep.optional
        then features
        else let
          name =
            if dep.rename != null
            then dep.rename
            else dep.name;
        in
          features // {${name} = ["dep:${name}"];};
    in
      foldl' maybeAddOptionalFeature (cargoToml.features or {}) dependencies;

    package = cargoToml.package;
  in {
    name = package.name;
    version = package.version;
    id = "${package.name} ${package.version} (path+file://${source})";

    dependencies = dependencies;
    features = featuresWithOptionalDepFeatuers;
    links = package.links or null;
    source = null;

    # procMacro = cargoToml.lib.proc-macro or false;

    # cargo defaults to "2015" if missing, for backwards compat.
    edition = package.edition or "2015";

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
  # resolveDepsFromLock
in {
  # foo = pkgInfo;
  #
  # inherit (inputs) registry-crates-io;
  #
  # defaultRegistries = defaultRegistries;

  fd = rec {
    name = "fd";

    src = pkgs.fetchFromGitHub {
      owner = "sharkdp";
      repo = name;
      rev = "68fe31da3f5da5d8d5b997d8919dc97e6eafead5";
      hash = "sha256-WH2rZ5fOZFt5BTN8QNhpY18CFsr6Lt5zJGgBuB2GvS8=";
    };

    metadata = cargoMetadata {inherit pkgs name src;};

    tree = cargoTree {inherit pkgs name src;};

    unitGraph = cargoUnitGraph {inherit pkgs name src;};

    manifest = fromTOML (readFile (src + "/Cargo.toml"));
    lock = fromTOML (readFile (src + "/Cargo.lock"));
    # We don't distinguish between v1 and v2. But v3 is different from both.
    lockVersionSet = {lockVersion = lock.version or 3;};

    selected = flatten (map (glob: globMatchDir glob src) manifest.workspace.members);
    excluded = map sanitizeRelativePath (manifest.workspace.exclude or []);
    workspaceMemberPaths = subtractLists excluded selected;

    # localSrcInfos : Attrset PkgInfo
    localSrcInfos =
      listToAttrs
      (map (
          relativePath: let
            # Path to cargo workspace member's directory.
            memberSource =
              if relativePath == ""
              then src
              else "${src}/${relativePath}";

            memberCargoToml = fromTOML (readFile "${memberSource}/Cargo.toml");
            memberManifest = mkPkgManifest {
              inherit (lockVersionSet) lockVersion;
              cargoToml = memberCargoToml;
              source = memberSource;
            };
          in {
            name = toPkgId memberCargoToml.package;
            value = memberManifest;
          }
        ) (
          if manifest ? workspace
          then workspaceMemberPaths
          else [""] # top-level crate
        ));

    gitSrcInfos = {}; # : Attrset PkgInfo
    registries = {}; # : Attrset Registry

    getPkgInfo = {
      source ? null,
      name,
      version,
      ...
    } @ args: let
      m = match "(registry|git)\\+([^#]*).*" source;
      kind = elemAt m 0;
      url = elemAt m 1;
    in
      # Local crates have no `source`.
      if source == null
      then
        localSrcInfos.${toPkgId args}
        or (throw "Local crate is outside the workspace: ${toPkgId args}")
        // {isLocalPkg = true;}
      else if m == null
      then throw "Invalid source: ${source}"
      else if kind == "registry"
      then
        getPkgInfoFromIndex
        (registries.${url}
          or (throw "Registry `${url}` not found. Please define it in `extraRegistries`."))
        args
        // {inherit source;} # `source` is for crate id, which is used for overrides.
      else if kind == "git"
      then
        gitSrcInfos.${url}
        or (throw "Git source `${url}` not found. Please define it in `gitSrcs`.")
      else throw "Invalid source: ${source}";
  };
}
