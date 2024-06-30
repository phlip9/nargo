{
  craneLib,
  nargoLib,
  pkgs,
}: let
  mkExample = {src}: let
    srcCleaned = craneLib.cleanCargoSource src;
  in rec {
    src = srcCleaned;
    cargoVendorDir = craneLib.vendorCargoDeps {src = srcCleaned;};
    metadata = nargoLib.generateCargoMetadata {
      inherit cargoVendorDir;
      src = srcCleaned;
    };
  };
in {
  #
  # Internal example crates
  #

  hello-world-bin = mkExample {src = ./hello-world-bin;};
  pkg-targets = mkExample {src = ./pkg-targets;};

  #
  # External crates
  #

  # non-trivial binary crate (not workspace)
  fd = mkExample {inherit (pkgs.fd) src;};

  # non-trivial binary crate (workspace)
  rage = mkExample {inherit (pkgs.rage) src;};

  # non-trivial binary crate (workspace)
  ripgrep = mkExample {inherit (pkgs.ripgrep) src;};

  # non-trivial
  hickory-dns = mkExample {inherit (pkgs.trust-dns) src;};

  # small crate
  cargo-hack = mkExample {inherit (pkgs.cargo-hack) src;};

  # non-trivial library (workspace)
  rand = mkExample rec {
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
}
