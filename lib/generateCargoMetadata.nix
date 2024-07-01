# Run `cargo metadata` on a crate or workspace in `src`.
{
  cargo,
  jq,
  pkgsBuildBuild,
  toml2json,
}:
#
{
  src,
  cargoVendorDir,
}:
#
pkgsBuildBuild.runCommandLocal "cargo-metadata" {
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

  set -x

  # "$out/Cargo.vendor.json"
  # "$out/Cargo.lock.json"
  jq \
    --indent 1 \
    --arg src "${src}" \
    -L "${./jq}" \
    'import "lib" as lib; . | lib::cleanCargoMetadata' \
    "$out/Cargo.metadata.raw.json" \
    > $out/Cargo.metadata.json

  set +x
''
