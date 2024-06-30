# Run `cargo metadata` on a crate or workspace in `src`.
{
  cargo,
  jq,
  pkgsBuildBuild,
}:
#
{
  src,
  cargoVendorDir,
}:
#
pkgsBuildBuild.runCommandLocal "Cargo.metadata.json" {
  depsBuildBuild = [cargo jq];
  env.cargoVendorDir = cargoVendorDir;
} ''
  export CARGO_TARGET_DIR="$PWD/target"
  export CARGO_HOME=$PWD/.cargo-home
  mkdir -p $CARGO_HOME
  cp $cargoVendorDir/config.toml $CARGO_HOME/config.toml

  cargo metadata \
    --manifest-path="${src}/Cargo.toml" \
    --offline \
    --locked \
    --format-version=1 \
    | jq --indent 1 \
      --arg src "${src}" \
      --arg cargoVendorDir "$cargoVendorDir" \
      -L "${./jq}" \
      'import "lib" as lib; . | lib::cleanCargoMetadata' \
    > $out
''
