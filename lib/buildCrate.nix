{
  lib,
  nargo-rustc,
  gcc,
}:
#
{
  buildPlatform,
  crateSrc,
  hostPlatform,
  pkgMetadata,
  rustc,
  target,
}:
#
lib.extendDerivation
# validate
true
# passthru
{
  metadata = pkgMetadata;
  target = target;
}
# derivation
(builtins.derivation {
  name = "${pkgMetadata.name}-${target.kind}-${pkgMetadata.version}";
  version = pkgMetadata.version;

  builder = "${nargo-rustc}/bin/nargo-rustc";

  outputs = ["out"];
  src = crateSrc;
  system = buildPlatform.system;

  # Envs
  BUILD_SCRIPT_DEP = target.build_script_dep;
  CRATE_TYPE = builtins.concatStringsSep "," target.crate_types;
  DEP_NAMES = builtins.map (dep: dep.dep_name) target.deps;
  DEP_CRATE_NAMES = builtins.map (dep: dep.crate_name) target.deps;
  DEP_PATHS = builtins.map (dep: dep.unit) target.deps;
  EDITION = target.edition;
  FEATURES = builtins.concatStringsSep "," (builtins.attrNames target.features);
  KIND = target.kind;
  LOG = "trace";
  # TODO(phlip9): need to place `rustc` in depsBuildBuild vs depsBuildHost (?)
  # depending on target/kind/etc.
  # TODO(phlip9): remove `gcc` when everything gets provided by rustup toolchains
  PATH = "${rustc}/bin:${gcc}/bin";
  PKG_NAME = pkgMetadata.name;
  TARGET_NAME = target.name;
  TARGET_PATH = target.path;
  TARGET_TRIPLE = hostPlatform.rust.rustcTarget;

  # # uncomment/incrememt to quickly rebuild full crate graph
  # FORCE_CACHE_MISS = 2;
})
