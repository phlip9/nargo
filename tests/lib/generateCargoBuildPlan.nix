{
  cargo,
  jq,
  pkgsBuildBuild,
}:
#
{
  name,
  # TODO(phlip9): filter `src` with `craneLib.mkDummySrc`
  src,
  cargoVendorDir,
  cargoExtraArgs ? [],
  hostTarget,
}:
#
let
  raw =
    pkgsBuildBuild.runCommandLocal "${name}-cargo-build-plan-raw" {
      depsBuildBuild = [cargo jq];
      env = {
        cargoVendorDir = cargoVendorDir;
        cargoSrc = "${src}";
        cargoExtraArgs =
          if (builtins.isString cargoExtraArgs)
          then cargoExtraArgs
          else (builtins.concatStringsSep " " cargoExtraArgs);
        hostTarget = hostTarget;
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

      # Generate the `Cargo.build-plan.raw.json` file.
      RUSTC_BOOTSTRAP=1 cargo build \
        --build-plan -Z unstable-options \
        --manifest-path="$cargoSrc/Cargo.toml" \
        --frozen \
        --target=$hostTarget \
        $cargoExtraArgs \
        | jq . \
        > "$out/Cargo.build-plan.raw.json"

      set +x
    '';
in
  raw
