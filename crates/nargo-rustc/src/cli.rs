#![allow(dead_code)] // TODO(phlip9): remove

// Goals:
// 1. Keep each individual crate build .drv as small as possible
//    -> Try to precompute, preaggregate, and amortize as much as possible
//    -> pass common parameters as file? If some params are shared between all
//       normal crates or build crates, then we can package them up into a file
//       and just pass the one file to all crate drvs
//    -> what is the threshold for pass inline vs pass as file? 128 B?

// Plan:
//
// -> precompute base "build" and "normal" profile

/*
CARGO=/home/phlip9/.rustup/toolchains/nightly-2024-05-03-x86_64-unknown-linux-gnu/bin/cargo
CARGO_CRATE_NAME=unicode_ident
CARGO_MANIFEST_DIR=/home/phlip9/.cargo/registry/src/index.crates.io-6f17d22bba15001f/unicode-ident-1.0.12
CARGO_PKG_AUTHORS='David Tolnay <dtolnay@gmail.com>'
CARGO_PKG_DESCRIPTION='Determine whether characters have the XID_Start or XID_Continue properties according to Unicode Standard Annex #31'
CARGO_PKG_HOMEPAGE=''
CARGO_PKG_LICENSE='(MIT OR Apache-2.0) AND Unicode-DFS-2016'
CARGO_PKG_LICENSE_FILE=''
CARGO_PKG_NAME=unicode-ident
CARGO_PKG_README=README.md
CARGO_PKG_REPOSITORY='https://github.com/dtolnay/unicode-ident'
CARGO_PKG_RUST_VERSION=1.31
CARGO_PKG_VERSION=1.0.12
CARGO_PKG_VERSION_MAJOR=1
CARGO_PKG_VERSION_MINOR=0
CARGO_PKG_VERSION_PATCH=12
CARGO_PKG_VERSION_PRE=''
CARGO_RUSTC_CURRENT_DIR=/home/phlip9/.cargo/registry/src/index.crates.io-6f17d22bba15001f/unicode-ident-1.0.12
LD_LIBRARY_PATH='/home/phlip9/dev/nargo/target/release/deps:/home/phlip9/.rustup/toolchains/nightly-2024-05-03-x86_64-unknown-linux-gnu/lib'
/home/phlip9/.rustup/toolchains/nightly-2024-05-03-x86_64-unknown-linux-gnu/bin/rustc
--crate-name unicode_ident
--edition=2018
/home/phlip9/.cargo/registry/src/index.crates.io-6f17d22bba15001f/unicode-ident-1.0.12/src/lib.rs
--error-format=json
--json=diagnostic-rendered-ansi,artifacts,future-incompat
--crate-type lib
--emit=dep-info,metadata,link
-C embed-bitcode=no
-C debug-assertions=off
-C metadata=e690205d23816ca7
-C extra-filename=-e690205d23816ca7
--out-dir /home/phlip9/dev/nargo/target/release/deps
-C strip=debuginfo
-L dependency=/home/phlip9/dev/nargo/target/release/deps
--cap-lints warn
*/

const HELP: &str = r#"
nargo-rustc

USAGE:
  nargo-rustc [OPTIONS]
"#;

pub struct Args {
    crate_name: String,
    crate_type: String,
    edition: String,
    version: String,
    target: String,
    features: String,
}

impl Args {
    pub fn from_env() -> Result<Self, lexopt::Error> {
        use lexopt::prelude::*;

        eprintln!("\n\nenvs:\n");
        for (key, var) in std::env::vars() {
            eprintln!("  {key}={var}");
        }

        todo!()
    }

    pub fn run(self) {
        todo!()
    }
}
