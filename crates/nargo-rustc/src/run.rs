//! Actually run `rustc`

use std::{
    ffi::OsStr,
    fs::File,
    path::{Path, PathBuf},
    process::Command,
    str::FromStr,
};

use nargo_core::{
    fs,
    nargo::{CrateType, TargetKind},
    time,
};

use crate::cli;

pub(crate) struct BuildContext {
    pkg_name: String,
    target: Target,
    target_triple: String,
    src: PathBuf,
    out: PathBuf,
}

struct Target {
    #[allow(dead_code)] // TODO(phlip9): remove
    name: String,
    version: semver::Version,
    kind: TargetKind,
    crate_name: String,
    #[allow(dead_code)] // TODO(phlip9): remove
    crate_types: Vec<CrateType>,
    crate_types_str: String,
    path: PathBuf,
    edition: String,
    features: String,
}

impl BuildContext {
    pub(crate) fn from_args(args: cli::Args) -> Self {
        let crate_name = args.target_name.replace('-', "_").to_owned();
        let crate_types = args
            .crate_type
            .split(',')
            .map(CrateType::from_str)
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        let kind = TargetKind::from_str(&args.kind).unwrap();

        let target = Target {
            name: args.target_name,
            version: args.version,
            kind,
            crate_name,
            crate_types,
            crate_types_str: args.crate_type,
            path: args.path,
            edition: args.edition,
            features: args.features,
        };

        Self {
            pkg_name: args.pkg_name,
            target,
            target_triple: args.target,
            src: args.src,
            out: args.out,
        }
    }

    fn is_custom_build(&self) -> bool {
        self.target.kind == TargetKind::CustomBuild
    }

    pub(crate) fn run(&self) {
        self.run_rustc();

        if self.is_custom_build() {
            self.run_build_script();
        }
    }

    fn run_rustc(&self) {
        // run: `rustc` compile

        // format!("{src}=/build/{pkg_name}-{version}")
        let remap = {
            let mut remap = self.src.clone().into_os_string();
            let remap_to = Path::new("/build")
                .join(format!("{}-{}", self.pkg_name, self.target.version));
            remap.push("=");
            remap.push(remap_to.as_os_str());
            remap
        };

        let target_path = self.src.join(&self.target.path);

        let mut cmd = Command::new("rustc");
        cmd.current_dir(&self.src);
        cmd.args(["--crate-name", &self.target.crate_name])
            .args(["--crate-type", &self.target.crate_types_str])
            .args(["--edition", &self.target.edition])
            .args([OsStr::new("--remap-path-prefix"), &remap])
            .args([OsStr::new("--out-dir"), self.out.as_os_str()])
            .args(["--emit", "link"])
            .args(["--target", &self.target_triple])
            .arg("-Copt-level=3")
            .arg("-Cdebug-assertions=off")
            .arg("-Cpanic=abort")
            .arg("--error-format=human")
            .arg("--diagnostic-width=80")
            .arg("-Cembed-bitcode=no")
            .arg("-Cstrip=debuginfo")
            .arg("--cap-lints=allow");

        // TODO(phlip9): if `edition` is unstable for this compiler release,
        // add `-Zunstable-options`

        // TODO(phlip9): `-Zallow-features` for unstable features in config.toml

        // --cfg feature="{feature}"
        for feature in self.target.features.split(',') {
            cmd.arg("--cfg");
            cmd.arg(format!("feature=\"{feature}\""));
        }

        cmd.arg(target_path);

        // envs
        cmd.env("CARGO_CRATE_NAME", &self.target.crate_name)
            .env("CARGO_MANIFEST_DIR", &self.src);

        // CARGO_PKG_<...> envs
        cmd.envs_cargo_pkg(self);

        eprint!("{}", cmd.to_string_debug());

        let status =
            time!("run rustc", cmd.status()).expect("failed to run `rustc`");
        if !status.success() {
            let code = status.code().unwrap_or(1);
            panic!("`rustc` exited with non-zero exit code: {code}");
        }
    }

    fn run_build_script(&self) {
        // run: $out/build_script_build 1>$out/output 2>$out/stderr
        //
        // TODO(phlip9): faithfully impl <src/cargo/core/compiler/custom_build.rs>

        let mut cmd = Command::new(self.out.join(&self.target.crate_name));
        cmd.current_dir(&self.src)
            .stdout(File::create(self.out.join("output")).expect("$out/output"))
            .stderr(
                File::create(self.out.join("stderr")).expect("$out/stderr"),
            );

        let out_dir = self.out.join("out");
        fs::create_dir(&out_dir).expect("create_dir");

        cmd.env("CARGO", "") // TODO
            .env("CARGO_MANIFEST_DIR", &self.src)
            .env("CARGO_MANIFEST_LINKS", "") // TODO
            .env("CARGO_MAKEFLAGS", "") // TODO
            .env("OUT_DIR", &out_dir);

        // cfg envs
        // TODO(phlip9): need to pass in
        cmd.env("CARGO_CFG_OVERFLOW_CHECKS", "")
            .env("CARGO_CFG_PANIC", "abort")
            .env("CARGO_CFG_RELOCATION_MODEL", "pic")
            .env("CARGO_CFG_TARGET_ABI", "")
            .env("CARGO_CFG_TARGET_ARCH", "x86_64")
            .env("CARGO_CFG_TARGET_ENDIAN", "little")
            .env("CARGO_CFG_TARGET_ENV", "gnu")
            .env("CARGO_CFG_TARGET_FAMILY", "unix")
            .env("CARGO_CFG_TARGET_FEATURE", "fxsr,sse,sse2")
            .env("CARGO_CFG_TARGET_HAS_ATOMIC", "16,32,64,8,ptr")
            .env(
                "CARGO_CFG_TARGET_HAS_ATOMIC_EQUAL_ALIGNMENT",
                "16,32,64,8,ptr",
            )
            .env("CARGO_CFG_TARGET_HAS_ATOMIC_LOAD_STORE", "16,32,64,8,ptr")
            .env("CARGO_CFG_TARGET_OS", "linux")
            .env("CARGO_CFG_TARGET_POINTER_WIDTH", "64")
            .env("CARGO_CFG_TARGET_THREAD_LOCAL", "")
            .env("CARGO_CFG_TARGET_VENDOR", "unknown")
            .env("CARGO_CFG_UB_CHECKS", "")
            .env("CARGO_CFG_UNIX", "")
            .env("CARGO_ENCODED_RUSTFLAGS", "")
            .env("DEBUG", "false")
            .env("HOST", "x86_64-unknown-linux-gnu")
            .env("OPT_LEVEL", "3")
            .env("PROFILE", "release")
            .env("RUSTC", "rustc")
            .env("RUSTDOC", "rustdoc")
            .env("TARGET", "x86_64-unknown-linux-gnu");

        // TODO(phlip9): `links`, `DEP_<name>_<key>`, `NUM_JOBS`, `RUSTC_LINKER`

        // CARGO_PKG_<...> envs
        cmd.envs_cargo_pkg(self);

        // CARGO_FEATURE_<feature>=1 envs
        let mut feature_key = String::new();
        for feature in self.target.features.split(',') {
            const PREFIX: &str = "CARGO_FEATURE_";
            feature_key.clear();
            feature_key.reserve_exact(PREFIX.len() + feature.len());
            feature_key.push_str(PREFIX);
            for c in feature.chars() {
                let c = c.to_ascii_uppercase();
                let c = if c == '-' { '_' } else { c };
                feature_key.push(c);
            }
            cmd.env(&feature_key, "1");
        }

        // TODO(phlip9): parse `cargo::error=MESSAGE` and `cargo::warning=MESSAGE`
        //               then fail build if any errors.

        eprint!("{}", cmd.to_string_debug());

        let status = time!("run build_script_build", cmd.status())
            .expect("failed to run `$out/build_script_build`");
        if !status.success() {
            let code = status.code().unwrap_or(1);
            panic!("`$out/build_script_build` exited with non-zero exit code: {code}");
        }

        // TODO(phlip9): we should probably filter the stdout to only useful
        // output and log the rest.
    }
}

trait CommandExt {
    fn to_string_debug(&self) -> String;
    fn envs_cargo_pkg(&mut self, ctx: &BuildContext) -> &mut Self;
}

impl CommandExt for Command {
    /// Serialize the `Command` as a human-readable string that you could
    /// (probably) run in a shell.
    /// TODO(phlip9): shell escape values
    fn to_string_debug(&self) -> String {
        let mut out = String::with_capacity(2048);

        // write the envs
        for (key, maybe_val) in self.get_envs() {
            let val = match maybe_val {
                Some(val) => val,
                None => continue,
            };
            let key = key.to_string_lossy();
            let val = val.to_string_lossy();
            out.push_str(&key);
            out.push('=');
            out.push_str(&val);
            out.push_str(" \\\n");
        }

        // write the program by itself
        out.push_str(&self.get_program().to_string_lossy());
        out.push_str(" \\\n");

        // place each arg on its own line. If it's an option (starts with '-')
        // we'll also try to pair it with the option value on the same line.
        let mut args =
            self.get_args().map(|arg| arg.to_string_lossy()).peekable();
        while let Some(arg) = args.next() {
            out.push_str("  ");
            out.push_str(&arg);

            let is_opt = arg.starts_with('-');
            if is_opt {
                let is_next_opt =
                    args.peek().map(|arg| arg.starts_with('-')).unwrap_or(true);

                if !is_next_opt {
                    let next_arg = args.next().expect("Must be Some");
                    out.push(' ');
                    out.push_str(&next_arg);
                }
            }

            if args.peek().is_some() {
                out.push_str(" \\\n");
            } else {
                out.push('\n');
            }
        }

        // dbg!(out.len());

        out
    }

    /// Add all the `CARGO_PKG_<...>` envs
    fn envs_cargo_pkg(&mut self, ctx: &BuildContext) -> &mut Self {
        let target = &ctx.target;
        self.env("CARGO_PKG_AUTHORS", "") // TODO
            .env("CARGO_PKG_DESCRIPTION", "") // TODO
            .env("CARGO_PKG_HOMEPAGE", "") // TODO
            .env("CARGO_PKG_LICENSE", "") // TODO
            .env("CARGO_PKG_LICENSE_FILE", "") // TODO
            .env("CARGO_PKG_NAME", &ctx.pkg_name)
            .env("CARGO_PKG_README", "") // TODO
            .env("CARGO_PKG_REPOSITORY", "") // TODO
            .env("CARGO_PKG_RUST_VERSION", "") // TODO
            .env("CARGO_PKG_VERSION", target.version.to_string())
            .env("CARGO_PKG_VERSION_MAJOR", target.version.major.to_string())
            .env("CARGO_PKG_VERSION_MINOR", target.version.minor.to_string())
            .env("CARGO_PKG_VERSION_PATCH", target.version.patch.to_string())
            .env("CARGO_PKG_VERSION_PRE", target.version.pre.as_str())
    }
}
