# nargo

A fast, granular Rust build system with perfect, global caching using Nix.

* No `cargo` during the build. Invokes `rustc` directly.
* Maximal granularity. Minimal derivations.
* Incremental builds in large Rust workspaces.
* Avoid IFD and get fast dependency pre-fetching with `Cargo.metadata.json`
  codegen.

_WARNING:_ nargo is alpha software and doesn't support many features like
cross-compiling, building crates with native dependencies, building tests,
running clippy, and more. APIs are unstable and subject to change at any time.

## About

Nargo is a [cargo](https://github.com/rust-lang/cargo) reimplementation that
uses nix to build each crate-target in an pure, isolated, and hermetic way.

While there are many approaches for building Rust projects in nix, nargo focuses
on _large Rust workspaces_ with many crates, where one-step or two-step build
granularity (a la `buildRustPackage` or `crane`) is insufficient. These
coarse-grained builders require rebuilding all workspace crates if any single
workspace crate changes, which happens frequently in a large Rust project.
