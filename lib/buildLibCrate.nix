{}:
#
{
  pkgs,
  pkgMetadata,
  crateSrc,
  target,
}:
#
pkgs.stdenv.mkDerivation rec {
  # TODO(phlip9): special case bin target?
  pname = "${pkgMetadata.name}-${target.kind}";
  version = "${pkgMetadata.version}";

  src = crateSrc;

  depsBuildBuild = [pkgs.rustc];

  phases = ["buildPhase"];

  # TODO(phlip9): do we need -Cmetadata=XXXX and -Cextra-filename=-XXXX?
  buildPhase = ''
    set -x

    ls -lah $src

    mkdir $out
    rustc \
      --crate-name="${target.crate_name}" \
      --crate-type="${builtins.concatStringsSep "," target.crate_types}" \
      ${builtins.concatStringsSep " " (builtins.map (feat: "--cfg feature=\\\"${feat}\\\"") (builtins.attrNames target.features))} \
      --edition="${target.edition}" \
      --remap-path-prefix "$src"="/build/${pname}-${version}" \
      --out-dir=$out \
      --emit=metadata,link \
      --target=x86_64-unknown-linux-gnu \
      -Copt-level=3 \
      -Cpanic=abort \
      --error-format=human \
      --diagnostic-width=80 \
      -Cembed-bitcode=no \
      -Cstrip=debuginfo \
      --cap-lints=allow \
      "$src/${target.path}"

    ls -lah $out

    set +x
  '';

  passthru = {
    metadata = pkgMetadata;
    target = target;
  };
}
