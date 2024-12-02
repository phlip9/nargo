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

/*
anyhow-custom-build>

NIX_BUILD_CORES=12
depsHostHost=
src=/nix/store/ppw97p0r7h5wk5y83xaw4ylqvrvkrqwk-crate-anyhow-1.0.86
out=/nix/store/dg8ic8rg6ggxbhv53h4yif4alqfiph2y-anyhow-custom-build-1.0.86
version=1.0.86
NIX_BUILD_TOP=/build

SHELL=/nix/store/717iy55ncqs0wmhdkwc5fg2vci5wbmq8-bash-5.2p32/bin/bash
NIX_BUILD_CORES=12
configureFlags=
mesonFlags=
shell=/nix/store/717iy55ncqs0wmhdkwc5fg2vci5wbmq8-bash-5.2p32/bin/bash
depsHostHost=
STRINGS=strings
src=/nix/store/ppw97p0r7h5wk5y83xaw4ylqvrvkrqwk-crate-anyhow-1.0.86
depsTargetTarget=
stdenv=/nix/store/ncv68hjnidcd2bm5abkhklrijhn0cgn6-stdenv-linux
builder=/nix/store/717iy55ncqs0wmhdkwc5fg2vci5wbmq8-bash-5.2p32/bin/bash
phases=buildPhase
PWD=/build
SOURCE_DATE_EPOCH=315532800
pname=anyhow-custom-build
NIX_ENFORCE_NO_NATIVE=1
CXX=g++
TEMPDIR=/build
system=x86_64-linux
TZ=UTC
HOST_PATH=/nix/store/ph44jcx3ddmlwh394mh1wb7f1qigxqb1-coreutils-9.5/bin:/nix/store/yb8icljkwhk5lla4nci3myndq2m4ywly-findutils-4.10.0/bin:/nix/store/phqahkhjsk8sl2jjiid1d47l2s4wy33h-diffutils-3.10/bin:/nix/store/yd9vbyhbxx62j0cyhd6v0iacz11nxpvc-gnused-4.9/bin:/nix/store/lvnwdmnjm7nvaq0a3vhvvn46iy4ql7gr-gnugrep-3.11/bin:/nix/store/0np7q7np75csai2cwzx57n332vn9ig4i-gawk-5.2.2/bin:/nix/store/zvn9bvrl2g516d2hfnanljiw24qa6w8l-gnutar-1.35/bin:/nix/store/db379c3zrmncmbv5khqxpk6ggbhxjw61-gzip-1.13/bin:/nix/store/girfp68w14pxfii52ak8gcs212y4q2s2-bzip2-1.0.8-bin/bin:/nix/store/21y3gqgm2a3w94m0wcrz1xxshks80z7p-gnumake-4.4.1/bin:/nix/store/717iy55ncqs0wmhdkwc5fg2vci5wbmq8-bash-5.2p32/bin:/nix/store/91ixz3zw9ipc5j93gybir9fp5mzisq8w-patch-2.7.6/bin:/nix/store/6v73xwg2c7p5ap29ckyg18ng87pzlnxs-xz-5.6.2-bin/bin:/nix/store/a6nsbir3y5ni3wwkw933aqvcmyyywnnz-file-5.45/bin
doInstallCheck=
HOME=/homeless-shelter
NIX_BINTOOLS=/nix/store/l7n97992gd5piaw8phkxzsz176gfk1yj-binutils-wrapper-2.43.1
GZIP_NO_TIMESTAMPS=1
depsTargetTargetPropagated=
cmakeFlags=
NIX_SSL_CERT_FILE=/no-cert-file.crt
version=1.0.86
outputs=out
NIX_STORE=/nix/store
TMPDIR=/build
LD=ld
NIX_ENFORCE_PURITY=1
buildPhase= ...
READELF=readelf
doCheck=
NIX_LOG_FD=2
depsBuildBuild=/nix/store/csadsvzmnzvb952kjky9ziinky5q8abr-rustc-wrapper-1.81.0 /nix/store/57w1j7l0qm47qirpzv94d3qlmr6a9qj1-nargo-rustc-0.1.0
TERM=xterm-256color
SIZE=size
propagatedNativeBuildInputs=
strictDeps=
AR=ar
AS=as
TEMP=/build
NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1
SHLVL=1
NIX_BUILD_TOP=/build
NM=nm
NIX_CFLAGS_COMPILE= -frandom-seed=dg8ic8rg6g
patches=
buildInputs=
SSL_CERT_FILE=/no-cert-file.crt
depsBuildTarget=
OBJCOPY=objcopy
out=/nix/store/dg8ic8rg6ggxbhv53h4yif4alqfiph2y-anyhow-custom-build-1.0.86
STRIP=strip
XDG_DATA_DIRS=/nix/store/dvfb5mrpfhg5211v6pl0a3fmz9idg6w7-patchelf-0.15.0/share
TMP=/build
OBJDUMP=objdump
PATH=/nix/store/csadsvzmnzvb952kjky9ziinky5q8abr-rustc-wrapper-1.81.0/bin:/nix/store/57w1j7l0qm47qirpzv94d3qlmr6a9qj1-nargo-rustc-0.1.0/bin:/nix/store/dvfb5mrpfhg5211v6pl0a3fmz9idg6w7-patchelf-0.15.0/bin:/nix/store/vh9fsdhgxcnab2qk7vdp2palkkn6j3cp-gcc-wrapper-13.3.0/bin:/nix/store/0vsyw5bhwmisszyfd1a0sdnwvnf4qa5a-gcc-13.3.0/bin:/nix/store/vpsla1ivhavzd4fmi95yzmgb4g9rd072-glibc-2.40-36-bin/bin:/nix/store/ph44jcx3ddmlwh394mh1wb7f1qigxqb1-coreutils-9.5/bin:/nix/store/l7n97992gd5piaw8phkxzsz176gfk1yj-binutils-wrapper-2.43.1/bin:/nix/store/vcvhwiilizhijk7ywyn58p9l005n9sbn-binutils-2.43.1/bin:/nix/store/ph44jcx3ddmlwh394mh1wb7f1qigxqb1-coreutils-9.5/bin:/nix/store/yb8icljkwhk5lla4nci3myndq2m4ywly-findutils-4.10.0/bin:/nix/store/phqahkhjsk8sl2jjiid1d47l2s4wy33h-diffutils-3.10/bin:/nix/store/yd9vbyhbxx62j0cyhd6v0iacz11nxpvc-gnused-4.9/bin:/nix/store/lvnwdmnjm7nvaq0a3vhvvn46iy4ql7gr-gnugrep-3.11/bin:/nix/store/0np7q7np75csai2cwzx57n332vn9ig4i-gawk-5.2.2/bin:/nix/store/zvn9bvrl2g516d2hfnanljiw24qa6w8l-gnutar-1.35/bin:/nix/store/db379c3zrmncmbv5khqxpk6ggbhxjw61-gzip-1.13/bin:/nix/store/girfp68w14pxfii52ak8gcs212y4q2s2-bzip2-1.0.8-bin/bin:/nix/store/21y3gqgm2a3w94m0wcrz1xxshks80z7p-gnumake-4.4.1/bin:/nix/store/717iy55ncqs0wmhdkwc5fg2vci5wbmq8-bash-5.2p32/bin:/nix/store/91ixz3zw9ipc5j93gybir9fp5mzisq8w-patch-2.7.6/bin:/nix/store/6v73xwg2c7p5ap29ckyg18ng87pzlnxs-xz-5.6.2-bin/bin:/nix/store/a6nsbir3y5ni3wwkw933aqvcmyyywnnz-file-5.45/bin
propagatedBuildInputs=
CC=gcc
NIX_CC=/nix/store/vh9fsdhgxcnab2qk7vdp2palkkn6j3cp-gcc-wrapper-13.3.0
depsBuildTargetPropagated=
depsBuildBuildPropagated=
NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1
CONFIG_SHELL=/nix/store/717iy55ncqs0wmhdkwc5fg2vci5wbmq8-bash-5.2p32/bin/bash
__structuredAttrs=
RANLIB=ranlib
NIX_HARDENING_ENABLE=bindnow format fortify fortify3 pic relro stackprotector strictoverflow zerocallusedregs
NIX_LDFLAGS=-rpath /nix/store/dg8ic8rg6ggxbhv53h4yif4alqfiph2y-anyhow-custom-build-1.0.86/lib
nativeBuildInputs=
name=anyhow-custom-build-1.0.86
depsHostHostPropagated=
_=/nix/store/57w1j7l0qm47qirpzv94d3qlmr6a9qj1-nargo-rustc-0.1.0/bin/nargo-rustc
*/

use std::{env, path::PathBuf};

use crate::run;

const HELP: &str = r#"
nargo-rustc

USAGE:
  nargo-rustc [OPTIONS]

OPTIONS:
  TODO
"#;

const VERSION: &str =
    concat!(env!("CARGO_PKG_NAME"), " ", env!("CARGO_PKG_VERSION"), "\n");

#[derive(Debug)] // TODO(phlip9): remove
pub struct Args {
    // cli args
    pub(crate) pkg_name: String,
    pub(crate) kind: String,
    pub(crate) target_name: String,
    pub(crate) crate_type: String,
    pub(crate) path: PathBuf,
    pub(crate) edition: String,
    pub(crate) features: String,
    pub(crate) target: String,
    pub(crate) build_script_dep: Option<PathBuf>,
    pub(crate) deps: Vec<Dep>,

    // envs
    pub(crate) src: PathBuf,
    pub(crate) out: PathBuf,
    pub(crate) version: semver::Version,
}

#[derive(Debug)] // TODO(phlip9): remove
pub struct Dep {
    pub(crate) dep_name: String,
    pub(crate) crate_name: String,
    pub(crate) out: PathBuf,
}

impl Args {
    pub fn from_env() -> Result<Self, lexopt::Error> {
        use lexopt::prelude::*;

        // eprintln!("\n\nenvs:\n");
        // for (key, var) in std::env::vars() {
        //     eprintln!("  {key}={var}");
        // }

        // CLI args

        let mut pkg_name: Option<String> = None;
        let mut kind: Option<String> = None;
        let mut target_name: Option<String> = None;
        let mut crate_type: Option<String> = None;
        let mut path: Option<PathBuf> = None;
        let mut edition: Option<String> = None;
        let mut features: Option<String> = None;
        let mut target: Option<String> = None;
        let mut build_script_dep: Option<PathBuf> = None;
        let mut deps: Vec<Dep> = Vec::new();

        let mut parser = lexopt::Parser::from_env();
        while let Some(arg) = parser.next()? {
            match arg {
                Short('h') | Long("help") => {
                    print!("{}", HELP);
                    std::process::exit(0);
                }
                Short('V') | Long("version") => {
                    print!("{}", VERSION);
                    std::process::exit(0);
                }

                Long("pkg-name") if pkg_name.is_none() => {
                    pkg_name = Some(parser.value()?.string()?);
                }
                Long("kind") if kind.is_none() => {
                    kind = Some(parser.value()?.string()?);
                }
                Long("target-name") if target_name.is_none() => {
                    target_name = Some(parser.value()?.string()?);
                }
                Long("crate-type") if crate_type.is_none() => {
                    crate_type = Some(parser.value()?.string()?);
                }
                Long("path") if path.is_none() => {
                    path = Some(PathBuf::from(parser.value()?));
                }
                Long("edition") if edition.is_none() => {
                    edition = Some(parser.value()?.string()?);
                }
                Long("features") if features.is_none() => {
                    features = Some(parser.value()?.string()?);
                }
                Long("target") if target.is_none() => {
                    target = Some(parser.value()?.string()?);
                }
                Long("build-script-dep") if build_script_dep.is_none() => {
                    build_script_dep = Some(PathBuf::from(parser.value()?));
                }
                Long("dep") => {
                    let dep_name = parser.value()?.string()?;
                    let crate_name = parser.value()?.string()?;
                    let out = PathBuf::from(parser.value()?);
                    deps.push(Dep {
                        dep_name,
                        crate_name,
                        out,
                    });
                }

                _ => return Err(arg.unexpected()),
            }
        }

        // Env vars

        let src = PathBuf::from(
            env::var_os("src").ok_or("missing `src` directory env")?,
        );
        let out = PathBuf::from(
            env::var_os("out").ok_or("missing `out` directory env")?,
        );
        let version = semver::Version::parse(
            &env::var("version").map_err(|_| "missing `version` env")?,
        )
        .map_err(|err| {
            format!("`version` env is not a valid semver version: {err}")
        })?;

        Ok(Args {
            pkg_name: pkg_name.ok_or("missing --pkg-name")?,
            kind: kind.ok_or("missing --kind")?,
            target_name: target_name.ok_or("missing --target-name")?,
            crate_type: crate_type.ok_or("missing --crate-type")?,
            path: path.ok_or("missing --path")?,
            edition: edition.ok_or("missing --edition")?,
            features: features.ok_or("missing --features")?,
            target: target.ok_or("missing --target")?,
            build_script_dep,
            deps,
            src,
            out,
            version,
        })
    }

    pub fn run(self) {
        eprintln!("args: {self:#?}");

        run::BuildContext::from_args(self).run()
    }
}
