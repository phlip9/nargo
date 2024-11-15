{vendorCargoDep}:
#
{
  pkgs,
  pkgMetadata,
  target,
}:
#
pkgs.stdenv.mkDerivation rec {
  # TODO(phlip9): special case bin target?
  pname = "${pkgMetadata.name}-${target.kind}";
  version = "${pkgMetadata.version}";

  src =
    if (pkgMetadata ? path)
    then pkgMetadata.path
    else (vendorCargoDep pkgMetadata);

  depsBuildBuild = [pkgs.rustc];

  phases = ["buildPhase"];

  # TODO(phlip9): do we need -Cmetadata=XXXX and -Cextra-filename=-XXXX?
  buildPhase = ''
    set -x

    ls -lah $src

    mkdir $out
    rustc \
      --crate-name="${target.name}" \
      --edition="${target.edition}" \
      --error-format=human \
      --diagnostic-width=80 \
      --crate-type="${builtins.concatStringsSep "," target.crate_types}" \
      --emit=metadata,link \
      -Copt-level=3 \
      -Cpanic=abort \
      -Cembed-bitcode=no \
      --out-dir=$out \
      --target=x86_64-unknown-linux-gnu \
      -Cstrip=debuginfo \
      --cap-lints=allow \
      --remap-path-prefix "$src"="/build/${pname}-${version}" \
      "$src/${target.path}"

    ls -lah $out

    set +x
  '';

  passthru = {
    metadata = pkgMetadata;
    target = target;
  };
}
