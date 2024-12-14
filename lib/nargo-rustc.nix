# cargo build --bin nargo-resolve
{
  lib,
  stdenv,
  stdenvNoCC,
  pkgs,
  rustc,
  build,
  resolve,
}:
# NOTE(phlip9): we need to "manually" build `nargo-rustc` to bootstrap
stdenvNoCC.mkDerivation {
  pname = "nargo-rustc";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../crates;
    fileset = lib.fileset.unions [
      ../crates/nargo-core
      ../crates/nargo-rustc
    ];
  };

  depsBuildTarget = [rustc.unwrapped stdenv.cc];

  phases = ["buildPhase"];

  buildPhase = ''
    rustc_deps="$(mktemp -d)"
    src_nargo_core="$src/nargo-core"
    target_triple="${stdenvNoCC.hostPlatform.rust.rustcTarget}"

    # nargo-core (lib)
    rustc \
      --crate-name nargo_core \
      --crate-type lib \
      --edition 2021 \
      --remap-path-prefix "$src_nargo_core=/build/nargo-core" \
      --out-dir "$rustc_deps" \
      --target "$target_triple" \
      --error-format=human \
      --diagnostic-width=80 \
      --cap-lints=allow \
      --emit=link \
      -Copt-level=3 \
      -Cpanic=abort \
      -Cembed-bitcode=no \
      -Cdebug-assertions=off \
      --cfg 'feature="default"' \
      --check-cfg 'cfg(feature, values("default"))' \
      -Cstrip=debuginfo \
      "$src_nargo_core/src/lib.rs"

    src_nargo_rustc="$src/nargo-rustc"

    # nargo-rustc (lib)
    rustc \
      --crate-name nargo_rustc \
      --crate-type lib \
      --edition 2021 \
      --remap-path-prefix "$src_nargo_rustc=/build/nargo-rustc" \
      --out-dir "$rustc_deps" \
      --target "$target_triple" \
      --error-format=human \
      --diagnostic-width=80 \
      --cap-lints=allow \
      --emit=link \
      -Copt-level=3 \
      -Cpanic=abort \
      -Cembed-bitcode=no \
      -Cdebug-assertions=off \
      -Cstrip=debuginfo \
      --extern "nargo_core=$rustc_deps/libnargo_core.rlib" \
      -L "dependency=$rustc_deps" \
      "$src_nargo_rustc/src/lib.rs"

    # nargo-rustc (bin)
    mkdir -p "$out/bin" && cd "$out/bin" && \
    rustc \
      --crate-name nargo_rustc \
      --crate-type bin \
      --edition 2021 \
      --remap-path-prefix "$src_nargo_rustc=/build/nargo-rustc" \
      -o "nargo-rustc" \
      --target "$target_triple" \
      --error-format=human \
      --diagnostic-width=80 \
      --cap-lints=allow \
      --emit=link \
      -Copt-level=3 \
      -Cpanic=abort \
      -Cembed-bitcode=no \
      -Cdebug-assertions=off \
      -Cstrip=debuginfo \
      --extern "nargo_rustc=$rustc_deps/libnargo_rustc.rlib" \
      --extern "nargo_core=$rustc_deps/libnargo_core.rlib" \
      -L "dependency=$rustc_deps" \
      "$src_nargo_rustc/src/main.rs"
  '';

  doCheck = false;
  strictDeps = true;

  passthru = rec {
    buildTarget = "x86_64-unknown-linux-gnu";
    hostTarget = "x86_64-unknown-linux-gnu";
    rootPkgIds = ["crates/nargo-rustc#0.1.0"];

    metadata = builtins.fromJSON (builtins.readFile ../Cargo.metadata.json);

    resolved = resolve.resolveFeatures {
      metadata = metadata;
      rootPkgIds = rootPkgIds;
      buildTarget = buildTarget;
      hostTarget = hostTarget;
    };

    built = build.build {
      workspacePath = ../.;
      metadata = metadata;
      resolved = resolved;
      rootPkgIds = rootPkgIds;
      buildTarget = buildTarget;
      hostTarget = hostTarget;
      pkgsCross = pkgs; # TODO(phlip9): cross-compile
    };
  };
}
