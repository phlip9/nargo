#
# `nargoLib.buildCrate` - build a single crate target
#
{
  lib,
  nargo-rustc,
}:
#
{
  buildPlatform,
  crateSrc,
  hostPlatform,
  pkgMetadata,
  rustc,
  cc,
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
  # TODO(phlip9): remove `cc` when everything gets provided by rustup toolchains?
  PATH = "${rustc}/bin:${cc}/bin";
  PKG_NAME = pkgMetadata.name;
  TARGET_NAME = target.name;
  TARGET_PATH = target.path;
  TARGET_TRIPLE = hostPlatform.rust.rustcTarget;

  # Reduce build time wasted looking for substitutions that don't exist.
  # TODO(phlip9): make this configurable/overridable?
  #
  # > If this attribute is set to `false`, then Nix will always build this
  # > derivation (locally or remotely); it will not try to substitute its outputs.
  # > This is useful for derivations that are cheaper to build than to substitute.
  # >
  # > This can be ignored by setting `always-allow-substitutes` to `true`.
  allowSubstitutes = false;
})
