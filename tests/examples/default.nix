{
  craneLib,
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
}
