# Run `cargo metadata` on a crate or workspace in `src`.
{
  cargo,
  jq,
  pkgsBuildBuild,
  toml2json,
}:
#
{
  # TODO(phlip9): filter `src` with `craneLib.mkDummySrc`
  src,
  cargoVendorDir,
}:
#
let
  raw =
    pkgsBuildBuild.runCommandLocal "cargo-metadata-raw" {
      depsBuildBuild = [cargo jq toml2json];
      env.cargoVendorDir = cargoVendorDir;
    } ''
      export CARGO_TARGET_DIR="$PWD/target"
      export CARGO_HOME=$PWD/.cargo-home
      mkdir -p $CARGO_HOME
      cp $cargoVendorDir/config.toml $CARGO_HOME/config.toml

      mkdir $out

      # phlip9: for now, output these intermediate files as well. makes it easier
      # to debug.

      # Ingest Cargo.lock file
      local cargoLockJson
      cargoLockJson="$out/Cargo.lock.json"
      toml2json --pretty ${src}/Cargo.lock > $cargoLockJson
      # cargoLockJson=$(mktemp)
      # trap "rm $cargoLockJson" 0

      # Ingest vendored registry+gitdep info from 'vendorCargoDeps'
      local cargoVendorJson
      cargoVendorJson="$out/Cargo.vendor.json"
      toml2json --pretty $cargoVendorDir/config.toml > $cargoVendorJson
      # cargoVendorJson=$(mktemp)
      # trap "rm $cargoVendorJson" 0

      # cp $cargoLockJson $out/Cargo.lock.json
      # cp $cargoVendorJson $out/Cargo.vendor.json

      cargo metadata \
        --manifest-path="${src}/Cargo.toml" \
        --offline \
        --locked \
        --format-version=1 \
        --all-features \
        | jq . \
        > $out/Cargo.metadata.raw.json
    '';
in
  # do this in a separate derivation while I'm debugging
  pkgsBuildBuild.runCommandLocal "cargo-metadata" {
    depsBuildBuild = [jq];
    env.cargoVendorDir = cargoVendorDir;
  } ''
    mkdir $out
    ln -s ${raw}/Cargo.vendor.json $out/Cargo.vendor.json
    ln -s ${raw}/Cargo.lock.json $out/Cargo.lock.json
    ln -s ${raw}/Cargo.metadata.raw.json $out/Cargo.metadata.raw.json

    # set -x

    # "$out/Cargo.vendor.json"
    # "$out/Cargo.lock.json"

    # Incredible/horrifying awk script that tightens up jq's pretty print output
    # so that it's more readable and compact.
    # See: <https://stackoverflow.com/a/46819029>
    fmt_json_condensed() {
      awk \
       'function ltrim(x) { sub(/^ */, "", x); return x; }
        s && NF > 1 && $NF == "["  { s=s $0;               next}
        s && NF == 1 && $1 == "]," { print s "],";   s=""; next}
        s && NF == 1 && $1 == "["  { print s;        s=$0; next}
        s && NF == 1 && $1 == "{"  { print s; print; s=""; next}
        s && NF == 1 && $1 == "]"  { print s $1;     s=""; next}
        s && NF == 1 && $1 == "}"  { print s;        s=$0; next}
        s                          { s=s ltrim($0);        next}
        $NF == "["                 { s=$0;                 next}
        {print}'
    }

    # Generate the `Cargo.metadata.json` file with jq.
    jq \
      --indent 1 \
      --arg src "${src}" \
      -L "${./jq}" \
      'import "lib" as lib; . | lib::genCargoMetadata' \
      "${raw}/Cargo.metadata.raw.json" \
      | fmt_json_condensed \
      > $out/Cargo.metadata.json

    # set +x
  ''
