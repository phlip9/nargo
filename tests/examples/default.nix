{
  craneLib,
  inputs,
  nargoLib,
  pkgs,
}: let
  # imports
  inherit (builtins) baseNameOf;

  mkExample = {
    name,
    src,
  }: let
    srcCleaned = craneLib.cleanCargoSource src;
  in rec {
    src = srcCleaned;
    cargoVendorDir = craneLib.vendorCargoDeps {src = srcCleaned;};
    metadata = nargoLib.generateCargoMetadata {
      inherit cargoVendorDir name;
      src = srcCleaned;
    };
  };

  mkLocalExample = src:
    mkExample {
      src = src;
      name = baseNameOf src;
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
      src = inputs.crane + "/${path}";
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
  # External crates
  #

  # non-trivial binary crate (not workspace)
  fd = mkExample {inherit (pkgs.fd) name src;};

  # non-trivial binary crate (workspace)
  rage = mkExample {inherit (pkgs.rage) name src;};

  # non-trivial binary crate (workspace)
  ripgrep = mkExample {inherit (pkgs.ripgrep) name src;};

  # non-trivial
  hickory-dns = mkExample {inherit (pkgs.trust-dns) name src;};

  # small crate
  cargo-hack = mkExample {inherit (pkgs.cargo-hack) name src;};

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
  crane-illegal-bin = mkCraneExample "checks/illegal-bin";
  crane-manually-vendored = mkCraneExample "checks/manually-vendored";
  crane-no_std = mkCraneExample "checks/no_std";
  crane-overlapping-targets = mkCraneExample "checks/overlapping-targets";
  crane-proc-macro = mkCraneExample "checks/proc-macro";
  crane-simple = mkCraneExample "checks/simple";
  crane-simple-git = mkCraneExample "checks/simple-git";
  crane-simple-git-workspace-inheritance = mkCraneExample "checks/simple-git-workspace-inheritance";
  crane-simple-no-deps = mkCraneExample "checks/simple-no-deps";
  crane-simple-only-tests = mkCraneExample "checks/simple-only-tests";
  crane-simple-with-audit-toml = mkCraneExample "checks/simple-with-audit-toml";
  crane-simple-with-deny-toml = mkCraneExample "checks/simple-with-deny-toml";
  crane-trunk = mkCraneExample "checks/trunk";
  crane-trunk-outdated-bindgen = mkCraneExample "checks/trunk-outdated-bindgen";
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

  nargo-build-deps = mkNocargoExample "build-deps";
  nargo-build-feature-env-vars = mkNocargoExample "build-feature-env-vars";
  nargo-cap-lints = mkNocargoExample "cap-lints";
  nargo-crate-names = mkNocargoExample "crate-names";
  nargo-custom-lib-name = mkNocargoExample "custom-lib-name";
  nargo-features = mkNocargoExample "features";
  nargo-libz-dynamic = mkNocargoExample "libz-dynamic";
  nargo-libz-static = mkNocargoExample "libz-static";
  nargo-lto-fat = mkNocargoExample "lto-fat";
  nargo-lto-proc-macro = mkNocargoExample "lto-proc-macro";
  nargo-lto-thin = mkNocargoExample "lto-thin";
  nargo-tokio-app = mkNocargoExample "tokio-app";
  nargo-workspace-inline = mkNocargoExample "workspace-inline";
  nargo-workspace-proc-macro-lto = mkNocargoExample "workspace-proc-macro-lto";
  nargo-workspace-virtual = mkNocargoExample "workspace-virtual";
}
