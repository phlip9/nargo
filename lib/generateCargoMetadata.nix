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
      depsBuildBuild = [cargo jq];
      env = {
        cargoVendorDir = cargoVendorDir;
        cargoSrc = "${src}";
      };
    } ''
      export CARGO_TARGET_DIR="$PWD/target"
      export CARGO_HOME="$PWD/.cargo-home"
      mkdir "$CARGO_HOME"
      mkdir "$out"
      ln -s "$cargoVendorDir/config.toml" "$CARGO_HOME/config.toml"

      # phlip9: for now, link these intermediate files as well. makes it easier
      # to debug.
      ln -s "$cargoVendorDir/config.toml" "$out/config.toml"
      ln -s "$cargoSrc/Cargo.lock" "$out/Cargo.lock"

      set -x

      # Generate the `Cargo.metadata.raw.json` file.
      cargo metadata \
        --manifest-path="$cargoSrc/Cargo.toml" \
        --offline \
        --locked \
        --format-version=1 \
        --all-features \
        | jq . \
        > "$out/Cargo.metadata.raw.json"

      set +x
    '';
in
  # do this in a separate derivation while I'm debugging
  pkgsBuildBuild.runCommandLocal "${name}-cargo-metadata" {
    depsBuildBuild = [nargo-metadata];
    env = {
      raw = raw;
      cargoVendorDir = cargoVendorDir;
    };
  } ''
    mkdir $out

    # Also include links to these files from raw for easier debugging.
    ln -s "$raw/config.toml" "$out/config.toml"
    ln -s "$raw/Cargo.lock" "$out/Cargo.lock"
    ln -s "$raw/Cargo.metadata.raw.json" "$out/Cargo.metadata.raw.json"

    set -x

    # Generate the `Cargo.metadata.json` file.
    nargo-metadata \
      --input-raw-metadata "$raw/Cargo.metadata.raw.json" \
      --output-metadata "$out/Cargo.metadata.json" \
      --no-nix-prefetch \
      --assume-vendored

    set +x
  ''
