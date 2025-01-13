{
  craneLib,
  inputsTest,
  nargoLib,
  nargoTestLib,
  pkgs,
}: let
  # imports
  inherit (builtins) baseNameOf;

  mkExample = {
    name,
    src ? builtins.throw "Must specify `src` or `srcCleaned`",
    srcCleaned ? craneLib.cleanCargoSource src,
  }: rec {
    src = srcCleaned;
    cargoVendorDir = craneLib.vendorCargoDeps {src = srcCleaned;};

    metadataDrv = nargoTestLib.generateCargoMetadata {
      inherit cargoVendorDir name;
      src = srcCleaned;
    };
    metadataNoCtx = builtins.fromJSON (
      # To reduce the maintainence burden for all these example crates, I want to
      # reuse the zero-config `craneLib.vendorCargoDeps`.
      #
      # `nargo-metadata --assume-vendored` then passthrus each crate src's store
      # path into the `Cargo.metadata.json`. However, when we IFD it here, nix
      # complains that `fromJSON` is not allowed to refer to a store path.
      builtins.unsafeDiscardStringContext (
        builtins.readFile (metadataDrv + "/Cargo.metadata.json")
      )
    );
    # Since we removed the `metadataDrv` dependency from `metadataNoCtx` above,
    # we need to manually fixup each vendored package's `path` string-context so
    # that nix actually provides the `path` in `buildCrate` (or whatever
    # dependent derivation).
    metadata = fixupMetadataIFDPathContext metadataNoCtx metadataDrv;

    buildTarget = pkgs.buildPlatform.rust.rustcTarget;
    hostTarget = "x86_64-unknown-linux-gnu";

    resolved = nargoLib.resolve.resolveFeatures {
      inherit metadata buildTarget hostTarget;
    };

    # `cargo build --unit-graph`
    cargoUnitGraph =
      pkgs.pkgsBuildBuild.runCommandLocal "${name}-unit-graph.json" {
        depsBuildBuild = [pkgs.cargo];
        env = {
          inherit cargoVendorDir hostTarget;
          cargoSrc = "${srcCleaned}";
        };
      }
      ''
        export CARGO_TARGET_DIR="$PWD/target"
        export CARGO_HOME="$PWD/.cargo-home"
        mkdir "$CARGO_HOME"
        ln -s "$cargoVendorDir/config.toml" "$CARGO_HOME/config.toml"

        (
          set -x;

          cargo build --unit-graph --manifest-path="$cargoSrc/Cargo.toml" \
            --frozen --target="$hostTarget" -Z unstable-options \
            > "$out";

          set +x;
        )
      '';

    # Check that our feature resolution matches cargo's.
    # `nargo-resolve --unit-graph $cargoUnitGraph --resolve-features $resolveFeatures`
    checkResolveFeatures =
      pkgs.pkgsBuildBuild.runCommandLocal "${name}-check-resolve" {
        depsBuildBuild = [nargoLib.nargo-resolve];

        env = {
          inherit cargoUnitGraph hostTarget;
          cargoSrc = "${srcCleaned}";
        };

        # TODO(phlip9): this is more space-efficient, but harder to debug since
        # the file path is an ephemeral /build/.attr-<hash> path.
        # # Expose `resolveFeaturesJson` in the derivation as a file with path
        # # `$resolveFeaturesJsonPath`.
        # resolveFeaturesJson = builtins.toJSON resolveFeatures;
        # passAsFile = ["resolveFeaturesJson"];

        # Write the resolved features into a separate derivation so I can easily
        # copy-paste the `nargo-resolve` invocation when debugging.
        resolveFeaturesJsonPath = builtins.toFile "${name}-resolve.json" (builtins.toJSON resolved);
      } ''
        mkdir "$out"

        (
          set -x;

          nargo-resolve \
            --unit-graph "$cargoUnitGraph" \
            --resolve-features "$resolveFeaturesJsonPath" \
            --host-target "$hostTarget" \
            --workspace-root "$cargoSrc"

          set +x;
        )
      '';

    # Build with `nargoLib.buildPackage`
    build = nargoLib.buildPackage {
      pname = name;
      version = "0.0.0";
      workspacePath = srcCleaned;
      metadata = metadata;
      pkgsCross = pkgs;
    };

    # `nargoLib.buildGraph`
    buildGraph = nargoLib.buildGraph.buildGraph {
      workspacePath = srcCleaned;
      metadata = metadata;
      pkgsCross = pkgs;
      buildTarget = buildTarget;
      hostTarget = hostTarget;
      resolved = resolved;
    };
  };

  mkLocalExample = src:
    mkExample {
      src = src;
      name = baseNameOf src;
    };

  mkNixpkgsExample = pkg:
    mkExample {
      name = pkg.name;
      # nixpkgs rust packages are already cleaned
      srcCleaned = pkg.src;
    };

  nocargoSrc = pkgs.fetchFromGitHub {
    owner = "oxalica";
    repo = "nocargo";
    rev = "7fdb03e1be21411764271f2ec85187870f0a9428"; # 2024-01-08
    hash = "sha256-ZgVnsJ/Pw51o2Zg+WS4pU4EC0zj526qxj/2IXxyDMiY=";
  };

  mkNocargoExample = crate:
    mkExample {
      name = crate;
      src = nocargoSrc + "/tests/${crate}";
    };

  mkCraneExample = path:
    mkExample {
      name = baseNameOf path;
      src = inputsTest.crane + "/${path}";
    };

  # For a `Cargo.metadata.json` read from a derivation output (IFD), we need to
  # manually fixup the nix string-context for each vendored package `path`.
  #
  # Without this fixup nix won't actually make the `path` visible to the
  # `buildCrate` builder, as without the context it just considers the `path`
  # a plain string and not a derivation input.
  fixupMetadataIFDPathContext = metadata: metadataDrv: let
    metadataDrvCtx = builtins.getContext metadataDrv.outPath;

    fixupPkg = _name: pkg:
      if ! (pkg ? source && pkg ? path)
      then pkg
      else (pkg // {path = fixupPath pkg.path;});

    isImpureEval = builtins ? currentSystem;
    fixupPath =
      if isImpureEval
      # We can depend on the package src specifically here with `storePath`, but
      # it only works in nix-build/--impure eval mode.
      then builtins.storePath
      # In pure flakes eval we'll just have to add _all_ vendored cargo deps as
      # an input.
      # TODO(phlip9): when we have greater control over `vendorCargoDeps` we can
      # reference the specific package src derivation here.
      else (path: builtins.appendContext path metadataDrvCtx);
  in
    metadata
    // {
      packages = builtins.mapAttrs fixupPkg metadata.packages;
    };
in {
  #
  # Internal example crates
  #

  dep-versions = mkLocalExample ./dep-versions;
  dependency-v3 = mkLocalExample ./dependency-v3;
  hello-world-bin = mkLocalExample ./hello-world-bin;
  pkg-targets = mkLocalExample ./pkg-targets;

  #
  # nixpkgs rust packages
  #

  cargo-hack = mkNixpkgsExample pkgs.cargo-hack;
  fd = mkNixpkgsExample pkgs.fd;
  gitoxide = mkNixpkgsExample pkgs.gitoxide;
  hickory-dns = mkNixpkgsExample pkgs.trust-dns;
  nushell = mkNixpkgsExample pkgs.nushell;
  rage = mkNixpkgsExample pkgs.rage;
  ripgrep = mkNixpkgsExample pkgs.ripgrep;
  starlark-rust = mkNixpkgsExample pkgs.starlark-rust;
  wasmtime = mkNixpkgsExample pkgs.wasmtime;

  #
  # Github example crates
  #

  # non-trivial library (workspace)
  rand = mkExample {
    name = "rand";
    src =
      # Need to patch the original src to use their Cargo.lock.msrv
      pkgs.runCommandLocal "rand-patched" {
        src_raw = pkgs.fetchFromGitHub {
          owner = "rust-random";
          repo = "rand";
          rev = "bf0301bfe6d2360e6c86a6c58273f7069f027691"; # 2024-04-27
          hash = "sha256-ahiydkkJHwUX13eiGh2aCRSofbxvevk22oKMgLMOl2g=";
        };
      } ''
        mkdir -p $out
        cp -r $src_raw/* $out/
        cp $src_raw/Cargo.lock.msrv $out/Cargo.lock
      '';
  };

  #
  # crane tests/pkgs
  #

  crane-utils = mkCraneExample "pkgs/crane-utils";

  # TODO(phlip9): support cargo bindeps
  # crane-bindeps = mkCraneExample "checks/bindeps";
  crane-bzip2-sys = mkCraneExample "checks/bzip2-sys";
  crane-clippytest = mkCraneExample "checks/clippy/clippytest";
  crane-codesign = mkCraneExample "checks/codesign";
  crane-features = mkCraneExample "checks/features/features";
  crane-custom-dummy = mkCraneExample "checks/custom-dummy";
  crane-dependencyBuildScriptPerms = mkCraneExample "checks/dependencyBuildScriptPerms";
  crane-git-overlapping = mkCraneExample "checks/git-overlapping";
  crane-git-repo-with-many-crates = mkCraneExample "checks/git-repo-with-many-crates";
  crane-gitRevNoRef = mkCraneExample "checks/gitRevNoRef";
  crane-grpcio-test = mkCraneExample "checks/grpcio-test";
  crane-highs-sys-test = mkCraneExample "checks/highs-sys-test";
  # crane-illegal-bin = mkCraneExample "checks/illegal-bin";
  crane-manually-vendored = mkCraneExample "checks/manually-vendored";
  crane-no_std = mkCraneExample "checks/no_std";
  crane-overlapping-targets = mkCraneExample "checks/overlapping-targets";
  # TODO(phlip9): decide how to handle building proc-macro as top-level target
  # crane-proc-macro = mkCraneExample "checks/proc-macro";
  crane-simple = mkCraneExample "checks/simple";
  crane-simple-git = mkCraneExample "checks/simple-git";
  crane-simple-git-workspace-inheritance = mkCraneExample "checks/simple-git-workspace-inheritance";
  crane-simple-no-deps = mkCraneExample "checks/simple-no-deps";
  crane-simple-only-tests = mkCraneExample "checks/simple-only-tests";
  crane-simple-with-audit-toml = mkCraneExample "checks/simple-with-audit-toml";
  crane-simple-with-deny-toml = mkCraneExample "checks/simple-with-deny-toml";
  crane-trunk = mkCraneExample "checks/trunk";
  crane-various-targets = mkCraneExample "checks/various-targets";
  crane-with-build-script = mkCraneExample "checks/with-build-script";
  crane-with-build-script-custom = mkCraneExample "checks/with-build-script-custom";
  crane-with-libs = mkCraneExample "checks/with-libs";
  crane-with-libs-some-dep = mkCraneExample "checks/with-libs/some-dep";
  crane-workspace = mkCraneExample "checks/workspace";
  crane-workspace-git = mkCraneExample "checks/workspace-git";
  crane-workspace-hack = mkCraneExample "checks/workspace-hack";
  crane-workspace-inheritance = mkCraneExample "checks/workspace-inheritance";
  crane-workspace-not-at-root = mkCraneExample "checks/workspace-not-at-root/workspace";
  crane-workspace-root = mkCraneExample "checks/workspace-root";

  #
  # nocargo tests
  #

  nocargo-build-deps = mkNocargoExample "build-deps";
  nocargo-build-feature-env-vars = mkNocargoExample "build-feature-env-vars";
  nocargo-cap-lints = mkNocargoExample "cap-lints";
  nocargo-crate-names = mkNocargoExample "crate-names";
  nocargo-custom-lib-name = mkNocargoExample "custom-lib-name";
  nocargo-features = mkNocargoExample "features";
  nocargo-libz-dynamic = mkNocargoExample "libz-dynamic";
  nocargo-libz-static = mkNocargoExample "libz-static";
  nocargo-lto-fat = mkNocargoExample "lto-fat";
  nocargo-lto-proc-macro = mkNocargoExample "lto-proc-macro";
  nocargo-lto-thin = mkNocargoExample "lto-thin";
  nocargo-tokio-app = mkNocargoExample "tokio-app";
  nocargo-workspace-inline = mkNocargoExample "workspace-inline";
  nocargo-workspace-proc-macro-lto = mkNocargoExample "workspace-proc-macro-lto";
  nocargo-workspace-virtual = mkNocargoExample "workspace-virtual";
}
