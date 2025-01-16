{
  lib,
  craneLib,
  inputsTest,
  nargoLib,
  nargoTestLib,
  pkgs,
}: let
  # imports
  inherit (builtins) baseNameOf removeAttrs;

  mkExample = {
    name,
    src,
    ...
  } @ args: rec {
    cargoVendorDir = craneLib.vendorCargoDeps {src = src;};

    metadataDrv = nargoTestLib.generateCargoMetadata {
      inherit cargoVendorDir name;
      src = src;
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
          cargoSrc = "${src}";
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
          cargoSrc = "${src}";
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
    buildInner = nargoLib.buildPackage {
      pname = name;
      version = "0.0.0";
      workspacePath = src;
      metadata = metadata;
      pkgsCross = pkgs;

      lib = args.lib or false;
      bins = args.bins or true;
    };

    # Wrap `buildInner` with `lazyDerivation` to improve test collection time.
    # Otherwise we have to do some hefty IFD and eval to get the final top-level
    # derivation from `buildGraph`, just to check if the attr is a derivation.
    build = lib.lazyDerivation {
      derivation = buildInner;
      meta = {};
    };

    # `nargoLib.buildGraph`
    buildGraph = nargoLib.buildGraph.buildGraph {
      workspacePath = src;
      metadata = metadata;
      pkgsCross = pkgs;
      buildTarget = buildTarget;
      hostTarget = hostTarget;
      resolved = resolved;
    };
  };

  mkLocalExample = {src, ...} @ args:
    mkExample ({
        src = src;
        name = baseNameOf src;
      }
      // removeAttrs args ["src"]);

  mkNixpkgsExample = {pkg, ...} @ args:
    mkExample ({
        name = pkg.name;
        src = pkg.src;
      }
      // removeAttrs args ["pkg"]);

  nocargoSrc = pkgs.fetchFromGitHub {
    owner = "oxalica";
    repo = "nocargo";
    rev = "7fdb03e1be21411764271f2ec85187870f0a9428"; # 2024-01-08
    hash = "sha256-ZgVnsJ/Pw51o2Zg+WS4pU4EC0zj526qxj/2IXxyDMiY=";
  };

  mkNocargoExample = {crate, ...} @ args:
    mkExample ({
        name = crate;
        src = nocargoSrc + "/tests/${crate}";
      }
      // removeAttrs args ["crate"]);

  mkCraneExample = {crate, ...} @ args:
    mkExample ({
        name = baseNameOf crate;
        src = inputsTest.crane + "/checks/${crate}";
      }
      // removeAttrs args ["crate"]);

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

  dep-versions = mkLocalExample {src = ./dep-versions;};
  dependency-v3 = mkLocalExample {src = ./dependency-v3;};
  hello-world-bin = mkLocalExample {src = ./hello-world-bin;};
  pkg-targets = mkLocalExample {src = ./pkg-targets;};

  #
  # nixpkgs rust packages
  #

  cargo-hack = mkNixpkgsExample {pkg = pkgs.cargo-hack;};
  fd = mkNixpkgsExample {pkg = pkgs.fd;};
  gitoxide = mkNixpkgsExample {pkg = pkgs.gitoxide;};
  hickory-dns = mkNixpkgsExample {pkg = pkgs.trust-dns;};
  nushell = mkNixpkgsExample {pkg = pkgs.nushell;};
  rage = mkNixpkgsExample {pkg = pkgs.rage;};
  ripgrep = mkNixpkgsExample {pkg = pkgs.ripgrep;};
  starlark-rust = mkNixpkgsExample {pkg = pkgs.starlark-rust;};
  wasmtime = mkNixpkgsExample {pkg = pkgs.wasmtime;};

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
    lib = true;
  };

  #
  # crane tests/pkgs
  #

  # TODO(phlip9): support cargo bindeps
  # crane-bindeps = mkCraneExample {crate = "bindeps";};
  crane-bzip2-sys = mkCraneExample {crate = "bzip2-sys";};
  crane-clippytest = mkCraneExample {crate = "clippy/clippytest";};
  crane-codesign = mkCraneExample {crate = "codesign";};
  crane-features = mkCraneExample {crate = "features/features";};
  crane-custom-dummy = mkCraneExample {crate = "custom-dummy";};
  crane-dependencyBuildScriptPerms = mkCraneExample {
    crate = "dependencyBuildScriptPerms";
    lib = true;
  };
  crane-git-overlapping = mkCraneExample {crate = "git-overlapping";};
  crane-git-repo-with-many-crates = mkCraneExample {crate = "git-repo-with-many-crates";};
  crane-gitRevNoRef = mkCraneExample {crate = "gitRevNoRef";};
  crane-grpcio-test = mkCraneExample {crate = "grpcio-test";};
  crane-highs-sys-test = mkCraneExample {crate = "highs-sys-test";};
  # crane-illegal-bin = mkCraneExample {crate = "illegal-bin";};
  crane-manually-vendored = mkCraneExample {crate = "manually-vendored";};
  crane-no_std = mkCraneExample {crate = "no_std";};
  crane-overlapping-targets = mkCraneExample {crate = "overlapping-targets";};
  crane-proc-macro = mkCraneExample {
    crate = "proc-macro";
    lib = true;
  };
  crane-simple = mkCraneExample {crate = "simple";};
  crane-simple-git = mkCraneExample {crate = "simple-git";};
  crane-simple-git-workspace-inheritance = mkCraneExample {crate = "simple-git-workspace-inheritance";};
  crane-simple-no-deps = mkCraneExample {crate = "simple-no-deps";};
  crane-simple-only-tests = mkCraneExample {
    crate = "simple-only-tests";
    lib = true;
  };
  crane-simple-with-audit-toml = mkCraneExample {crate = "simple-with-audit-toml";};
  crane-simple-with-deny-toml = mkCraneExample {crate = "simple-with-deny-toml";};
  crane-trunk = mkCraneExample {crate = "trunk";};
  crane-various-targets = mkCraneExample {crate = "various-targets";};
  crane-with-build-script = mkCraneExample {crate = "with-build-script";};
  crane-with-build-script-custom = mkCraneExample {crate = "with-build-script-custom";};
  crane-with-libs = mkCraneExample {
    crate = "with-libs";
    lib = true;
  };
  crane-with-libs-some-dep = mkCraneExample {
    crate = "with-libs/some-dep";
    lib = true;
  };
  crane-workspace = mkCraneExample {crate = "workspace";};
  crane-workspace-git = mkCraneExample {
    crate = "workspace-git";
    lib = true;
  };
  crane-workspace-hack = mkCraneExample {crate = "workspace-hack";};
  crane-workspace-inheritance = mkCraneExample {crate = "workspace-inheritance";};
  crane-workspace-not-at-root = mkCraneExample {crate = "workspace-not-at-root/workspace";};
  crane-workspace-root = mkCraneExample {crate = "workspace-root";};

  #
  # nocargo tests
  #

  nocargo-build-deps = mkNocargoExample {crate = "build-deps";};
  nocargo-build-feature-env-vars = mkNocargoExample {crate = "build-feature-env-vars";};
  nocargo-cap-lints = mkNocargoExample {crate = "cap-lints";};
  nocargo-crate-names = mkNocargoExample {crate = "crate-names";};
  nocargo-custom-lib-name = mkNocargoExample {crate = "custom-lib-name";};
  nocargo-features = mkNocargoExample {crate = "features";};
  nocargo-libz-dynamic = mkNocargoExample {crate = "libz-dynamic";};
  nocargo-libz-static = mkNocargoExample {crate = "libz-static";};
  nocargo-lto-fat = mkNocargoExample {crate = "lto-fat";};
  nocargo-lto-proc-macro = mkNocargoExample {crate = "lto-proc-macro";};
  nocargo-lto-thin = mkNocargoExample {crate = "lto-thin";};
  nocargo-tokio-app = mkNocargoExample {crate = "tokio-app";};
  nocargo-workspace-inline = mkNocargoExample {crate = "workspace-inline";};
  nocargo-workspace-proc-macro-lto = mkNocargoExample {
    crate = "workspace-proc-macro-lto";
    lib = true;
  };
  nocargo-workspace-virtual = mkNocargoExample {crate = "workspace-virtual";};
}
