{nargo-rustc}:
#
{
  pkgs,
  pkgMetadata,
  crateSrc,
  target,
}:
#
pkgs.stdenv.mkDerivation rec {
  pname = "${pkgMetadata.name}-${target.kind}";
  version = "${pkgMetadata.version}";

  src = crateSrc;

  # TODO(phlip9): need to place `rustc` in depsBuildBuild vs depsBuildHost (?)
  # depending on target/kind/etc.
  depsBuildBuild = [pkgs.rustc nargo-rustc];

  phases = ["buildPhase"];

  # TODO(phlip9): do we need -Cmetadata=XXXX and -Cextra-filename=-XXXX?
  buildPhase = ''
    nargo-rustc \
      --pkg-name "${pkgMetadata.name}" \
      --kind "${target.kind}" \
      --target-name "${target.name}" \
      --crate-type "${builtins.concatStringsSep "," target.crate_types}" \
      --path "${target.path}" \
      --edition "${target.edition}" \
      --features "${builtins.concatStringsSep "," (builtins.attrNames target.features)}" \
      --target x86_64-unknown-linux-gnu
  '';

  passthru = {
    metadata = pkgMetadata;
    target = target;
  };
}
