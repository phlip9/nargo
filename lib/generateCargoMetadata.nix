# Run `cargo metadata` on a crate or workspace in `src`.
{
  cargo,
  jq,
  nargo-metadata,
  pkgsBuildBuild,
  toml2json,
}:
#
{
  name,
  # TODO(phlip9): filter `src` with `craneLib.mkDummySrc`
  src,
  cargoVendorDir,
}:
#
let
  raw =
    pkgsBuildBuild.runCommandLocal "${name}-cargo-metadata-raw" {
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
  pkgsBuildBuild.runCommandLocal "${name}-cargo-metadata" {
    depsBuildBuild = [nargo-metadata];
    env = {
      raw = raw;
      workspaceSrc = "${src}";
    };
  } ''
    mkdir $out

    # Also include links to these files from raw for easier debugging.
    ln -s "$raw/Cargo.vendor.json" "$out/Cargo.vendor.json"
    ln -s "$raw/Cargo.lock.json" "$out/Cargo.lock.json"
    ln -s "$raw/Cargo.metadata.raw.json" "$out/Cargo.metadata.raw.json"

    set -x

    # Generate the `Cargo.metadata.json` file.
    nargo-metadata \
      --src "$workspaceSrc" \
      --metadata "$raw/Cargo.metadata.raw.json" \
      > $out/Cargo.metadata.json

    set +x
  ''
