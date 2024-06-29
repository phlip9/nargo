# Run `cargo metadata` on a crate or workspace in `src`.
{
  cargo,
  pkgsBuildBuild,
}:
#
{
  src,
  cargoVendorDir,
}:
#
pkgsBuildBuild.runCommandLocal "Cargo.metadata.json" {
  depsBuildBuild = [cargo];
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
    > $out
''
