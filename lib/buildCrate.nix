{nargo-rustc}:
#
{
  pkgs,
  pkgMetadata,
  crateSrc,
  target,
}:
#
pkgs.stdenv.mkDerivation {
  pname = "${pkgMetadata.name}-${target.kind}";
  version = "${pkgMetadata.version}";

  src = crateSrc;

  # TODO(phlip9): need to place `rustc` in depsBuildBuild vs depsBuildHost (?)
  # depending on target/kind/etc.
  # TODO(phlip9): use `rustc-unwrapped` to avoid bash overhead?
  depsBuildBuild = [pkgs.rustc nargo-rustc];

  phases = ["buildPhase"];

  # TODO(phlip9): remove `concatStringsSep` and `null` check when moving to
  # direct `derivation`.
  env = {
    BUILD_SCRIPT_DEP = let
      build_script_dep = target.build_script_dep;
    in
      if build_script_dep == null
      then ""
      else build_script_dep;
    CRATE_TYPE = builtins.concatStringsSep "," target.crate_types;
    DEP_NAMES = builtins.concatStringsSep " " (builtins.map (dep: dep.dep_name) target.deps);
    DEP_CRATE_NAMES = builtins.concatStringsSep " " (builtins.map (dep: dep.crate_name) target.deps);
    DEP_PATHS = builtins.concatStringsSep " " (builtins.map (dep: dep.unit) target.deps);
    EDITION = target.edition;
    FEATURES = builtins.concatStringsSep "," (builtins.attrNames target.features);
    KIND = target.kind;
    LOG = "info";
    PKG_NAME = pkgMetadata.name;
    TARGET_NAME = target.name;
    TARGET_PATH = target.path;
    TARGET_TRIPLE = "x86_64-unknown-linux-gnu";
  };

  buildPhase = ''
    nargo-rustc
  '';

  passthru = {
    metadata = pkgMetadata;
    target = target;
  };
}
