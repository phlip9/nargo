{}:
#
{
  pkgs,
  nargo-rustc,
  pkgMetadata,
  crateSrc,
  target,
}:
#
pkgs.stdenv.mkDerivation rec {
  pname = "${pkgMetadata.name}-${target.kind}";
  version = "${pkgMetadata.version}";

  src = crateSrc;

  depsBuildBuild = [pkgs.rustc nargo-rustc];

  phases = ["buildPhase"];

  # TODO(phlip9): do we need -Cmetadata=XXXX and -Cextra-filename=-XXXX?
  buildPhase = ''
    # set -x

    # pwd
    # ls -lah
    #
    # ls -lah $src

    nargo-rustc --help

    mkdir $out
    rustc \
      --crate-name="${target.crate_name}" \
      --crate-type="${builtins.concatStringsSep "," target.crate_types}" \
      ${builtins.concatStringsSep " " (builtins.map (feat: "--cfg feature=\\\"${feat}\\\"") (builtins.attrNames target.features))} \
      --edition="${target.edition}" \
      --remap-path-prefix "$src"="/build/${pname}-${version}" \
      --out-dir=$out \
      --emit=link \
      --target=x86_64-unknown-linux-gnu \
      -Copt-level=3 \
      -Cpanic=abort \
      --error-format=human \
      --diagnostic-width=80 \
      -Cembed-bitcode=no \
      -Cstrip=debuginfo \
      --cap-lints=allow \
      "$src/${target.path}"

    # mkdir $out/out
    # ls -lah $out

    pushd $src

    DEBUG=false \
    HOST="x86_64-unknown-linux-gnu" \
    OPT_LEVEL=3 \
    OUT_DIR=$out/out \
    PROFILE=release \
    RUSTC=rustc \
    RUSTDOC=rustdoc \
    TARGET="x86_64-unknown-linux-gnu" \
      $out/${target.crate_name} \
        1>$out/output \
        2>$out/stderr

    popd

    set +x
  '';

  passthru = {
    metadata = pkgMetadata;
    target = target;
  };
}
