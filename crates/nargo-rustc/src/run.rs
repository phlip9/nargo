//! Actually run `rustc`

use core::str;
use std::{
    borrow::Cow,
    collections::BTreeMap,
    ffi::{OsStr, OsString},
    fs::File,
    path::{self, Path, PathBuf},
    process::Command,
    str::FromStr,
};

use nargo_core::{
    fs,
    nargo::{CrateType, TargetKind},
    time, trace,
};

use crate::{
    build_script::BuildOutput, cli, semver, shell, target_cfg::RustcTargetCfg,
};

pub(crate) struct BuildContext<'a> {
    pkg_name: &'a str,
    target: Target<'a>,
    profile: Profile<'a>,
    target_triple: &'a str,
    host_profile: Option<Profile<'a>>,
    host_target_triple: Option<&'a str>,
    build_script_dep: Option<&'a Path>,
    deps: Vec<Dep<'a>>,
    src: &'a Path,
    out: &'a Path,
}

struct Target<'a> {
    name: &'a str,
    version: semver::Version<'a>,
    kind: TargetKind,
    crate_name: Cow<'a, str>,
    crate_types: Vec<CrateType>,
    crate_types_str: &'a str,
    path: &'a Path,
    edition: &'a str,
    features: Vec<&'a str>,
}

struct Profile<'a> {
    name: &'a str,
    opt_level: char,
    #[allow(dead_code)] // TODO(phlip9): remove
    lto: &'a str,
    // codegen_backend,
    codegen_units: Option<u32>,
    debuginfo: &'a str,
    debug_assertions: bool,
    #[allow(dead_code)] // TODO(phlip9): remove
    split_debuginfo: Option<&'a str>,
    overflow_checks: bool,
    rpath: bool,
    panic: &'static str,
    // incremental,
    strip: &'a str,
    // rustflags: profile_rustflags,
    // trim_paths,
}

struct Dep<'a> {
    /// The dep's name in this crate's Cargo.toml.
    dep_name: &'a str,
    /// The dep's original crate name.
    #[allow(dead_code)] // TODO(phlip9): remove
    crate_name: &'a str,
    /// The nix store path containing the dep's output artifacts.
    out: &'a Path,
    /// The relevant linkable libs we've discovered in the dep's out dir.
    libs: Vec<String>,
}

impl<'a> BuildContext<'a> {
    pub(crate) fn from_args(args: cli::Args<'a>) -> Self {
        let crate_name = if args.target_name.contains('-') {
            Cow::Owned(args.target_name.replace('-', "_"))
        } else {
            Cow::Borrowed(args.target_name)
        };
        let crate_types = args
            .crate_type
            .split(',')
            .map(CrateType::from_str)
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        let kind = TargetKind::from_str(args.kind).unwrap();
        let features = if args.features.is_empty() {
            Vec::new()
        } else {
            args.features.split(',').collect()
        };

        let target = Target {
            name: args.target_name,
            version: args.version,
            kind,
            crate_name,
            crate_types,
            crate_types_str: args.crate_type,
            path: args.target_path,
            edition: args.edition,
            features,
        };

        let profile = Profile {
            name: "debug",
            opt_level: '1',
            lto: "off",
            codegen_units: None,
            debuginfo: "0",
            debug_assertions: true,
            split_debuginfo: None,
            overflow_checks: true,
            rpath: false,
            panic: "abort",
            strip: "debuginfo",
        };

        // We need the build profile (nix "build", cargo "host") only when
        // _building_ the `build_script_build` binary.
        let host_profile = target.is_custom_build().then_some(Profile {
            name: "debug",
            opt_level: '0',
            lto: "off",
            codegen_units: None,
            debuginfo: "0",
            debug_assertions: true,
            split_debuginfo: None,
            overflow_checks: true,
            rpath: false,
            panic: "abort",
            strip: "debuginfo",
        });
        let host_target_triple =
            target.is_custom_build().then_some(args.target_triple);

        let deps = time!(
            "read direct deps",
            args.deps.into_iter().map(Dep::from_cli).collect()
        );

        Self {
            pkg_name: args.pkg_name,
            target,
            host_profile,
            host_target_triple,
            profile,
            target_triple: args.target_triple,
            build_script_dep: args.build_script_dep,
            deps,
            src: args.src,
            out: args.out,
        }
    }

    pub(crate) fn run(&self) {
        fs::create_dir(self.out).expect("mkdir");

        // Collect transitive deps into `$out/deps` so `rustc` can find them.
        let tdep_lib_filenames =
            time!("collect transitive deps", self.collect_transitive_deps());

        // Compile unit
        self.run_rustc();

        // For `build.rs` scripts, we also run the `build_script_build`
        if self.target.is_custom_build() {
            self.run_build_script();
        }

        // For targets that should propagate, also collect our direct deps into
        // `$out/deps`.
        if self.target.propagates_deps() {
            time!(
                "collect direct deps",
                self.collect_direct_deps(tdep_lib_filenames)
            );
        } else {
            let _ = time!(
                "clear deps dir",
                std::fs::remove_dir_all(self.out.join("deps"))
            );
        }
    }

    fn run_rustc(&self) {
        // run: `rustc` compile

        // format!("{src}=/build/{pkg_name}-{version}")
        let remap = {
            let mut remap = self.src.as_os_str().to_owned();
            let remap_to = Path::new("/build")
                .join(format!("{}-{}", self.pkg_name, self.target.version));
            remap.push("=");
            remap.push(remap_to.as_os_str());
            remap
        };

        let target_path = self.src.join(self.target.path);

        // build the build.rs script with the build profile/target triple, but
        // run the script with normal profile/target triple
        let profile = if self.target.is_custom_build() {
            self.host_profile.as_ref().unwrap()
        } else {
            &self.profile
        };
        let target_triple = if self.target.is_custom_build() {
            self.host_target_triple.as_ref().unwrap()
        } else {
            &self.target_triple
        };

        let mut cmd = Command::new("rustc");
        cmd.current_dir(self.src);
        cmd.args(["--crate-name", &self.target.crate_name])
            .args(["--crate-type", self.target.crate_types_str])
            .args(["--edition", self.target.edition])
            .args([OsStr::new("--remap-path-prefix"), &remap])
            .args(["--target", target_triple])
            .arg("--error-format=human")
            .arg("--diagnostic-width=80")
            .arg("--cap-lints=allow");

        //              bins: `-o $out/bin/${target.name}`
        // libs/custom-build: `--out-dir $out`
        //
        // TODO(phlip9): should probably put linkable libs into `lib` dir
        match self.target.kind {
            TargetKind::Bin
            | TargetKind::Test
            | TargetKind::Bench
            | TargetKind::ExampleBin => {
                let mut out_dir = self.out.join("bin");
                fs::create_dir(&out_dir).expect("mkdir");

                out_dir.push(self.target.name);
                let out_file = out_dir;

                cmd.args([OsStr::new("-o"), out_file.as_os_str()]);
            }
            TargetKind::Lib
            | TargetKind::ExampleLib
            | TargetKind::CustomBuild => {
                cmd.args([OsStr::new("--out-dir"), self.out.as_os_str()]);
            }
        };

        // TODO(phlip9): if `edition` is unstable for this compiler release,
        // add `-Zunstable-options`

        // TODO(phlip9): `-Zallow-features` for unstable features in config.toml

        // TODO(phlip9): `cargo check` => only `--emit=metadata`

        // TODO(phlip9): can we even do pipelining?
        // if self.target.requires_upstream_objects() {
        //     cmd.arg("--emit=link");
        // } else {
        //     cmd.arg("--emit=metadata,link");
        // }
        cmd.arg("--emit=link");

        // -C prefer-dynamic
        if self.target.is_proc_macro() || self.target.is_dylib() {
            cmd.arg("-Cprefer-dynamic");
        }

        // -C opt-level={}
        if profile.opt_level != '0' {
            cmd.arg(format!("-Copt-level={}", profile.opt_level));
        }

        // -C panic={}
        if profile.panic != "unwind" {
            cmd.arg(format!("-Cpanic={}", profile.panic));
        }

        // TODO(phlip9): LTO
        cmd.arg("-Cembed-bitcode=no");

        // TODO(phlip9): codegen backend

        if let Some(codegen_units) = profile.codegen_units {
            cmd.arg(format!("-Ccodegen-units={codegen_units}"));
        }

        // TODO(phlip9): debuginfo newtype
        if profile.debuginfo != "0" {
            cmd.arg(format!("-Cdebuginfo={}", profile.debuginfo));

            // TODO(phlip9): check if target platform supports split debuginfo
            // if let Some(split_debuginfo) = &profile.split_debuginfo {
            //
            // }
        }

        // TODO(phlip9): trim paths

        // `-C overflow-checks` is implied by the setting of `-C debug-assertions`,
        // so we only need to provide `-C overflow-checks` if it differs from
        // the value of `-C debug-assertions` we would provide.
        let opt_level = profile.opt_level;
        let debug_assertions = profile.debug_assertions;
        let overflow_checks = profile.overflow_checks;
        if opt_level != '0' {
            if debug_assertions {
                cmd.arg("-Cdebug-assertions=on");
                if !overflow_checks {
                    cmd.arg("-Coverflow-checks=off");
                }
            } else if overflow_checks {
                cmd.arg("-Coverflow-checks=on");
            }
        } else if !debug_assertions {
            cmd.arg("-Cdebug-assertions=off");
            if overflow_checks {
                cmd.arg("-Coverflow-checks=on");
            }
        } else if !overflow_checks {
            cmd.arg("-Coverflow-checks=off");
        }

        // TODO(phlip9): any test in unit => `--cfg test`

        // --cfg feature="{feature}"
        let features = &self.target.features;
        for feature in features {
            cmd.arg("--cfg");
            cmd.arg(format!("feature=\"{feature}\""));
        }

        // --check-cfg cfg(feature, values(...))
        if !features.is_empty() {
            let mut cfg = String::with_capacity(
                22 + 4 * features.len()
                    + features.iter().map(|s| s.len()).sum::<usize>(),
            );
            cfg.push_str("cfg(feature, values(");
            for (i, feature) in features.iter().enumerate() {
                if i != 0 {
                    cfg.push_str(", ");
                }
                cfg.push('"');
                cfg.push_str(feature);
                cfg.push('"');
            }
            cfg.push_str("))");

            cmd.arg("--check-cfg");
            cmd.arg(cfg);
        }

        // TODO(phlip9): is metadata from $out safe?
        let metadata = self.out.file_name().unwrap().as_encoded_bytes();
        let metadata = str::from_utf8(&metadata[..8]).unwrap();
        cmd.arg(format!("-Cmetadata={metadata}"));
        if self.target.uses_extra_filename() {
            cmd.arg(format!("-Cextra-filename=-{metadata}"));
        }

        if profile.rpath {
            cmd.arg("-Crpath");
        }

        // TODO(phlip9): -C linker={}

        if profile.strip != "none" {
            cmd.arg(format!("-Cstrip={}", profile.strip));
        }

        // TODO(phlip9): handle build std

        // direct deps: --extern <dep-name>=<lib-path>
        {
            let mut buf = OsString::new();
            for dep in &self.deps {
                cmd.arg("--extern");

                buf.clear();
                buf.push(OsStr::new(&dep.dep_name.replace('-', "_")));
                buf.push(OsStr::new("="));
                buf.push(dep.lib_path());
                cmd.arg(&buf);
            }
        }

        // proc-macro -> --extern proc_macro
        if self.target.is_proc_macro() {
            cmd.arg("--extern");
            cmd.arg("proc_macro");
        }

        // transitive deps: `-L dependency=${out}/deps` (via `collect_transitive_deps`)
        // TODO(phlip9): is there any downside to just using `all=`?
        if !self.deps.is_empty() {
            let mut buf = OsString::with_capacity(
                10 + 1 + self.out.as_os_str().len() + 1 + 4,
            );
            buf.push("dependency=");
            buf.push(self.out.as_os_str());
            buf.push(path::MAIN_SEPARATOR_STR);
            buf.push("deps");

            cmd.arg("-L");
            cmd.arg(buf);
        }

        // TODO(phlip9): have build.rs script => parse `<build-script-drv>/out`
        // 1. add `-l` and `-L` link flags
        // 2. add `-Clink-arg={}`
        // 3. plugins?
        if let Some(build_script_dep) = &self.build_script_dep {
            let path = build_script_dep.join("output");
            let bytes = fs::read_file(&path)
                .expect("failed to read build_script_build output")
                .expect("missing build_script_build output");

            let build_script_output = BuildOutput::parse(&bytes);
            for check_cfg in build_script_output.check_cfgs {
                cmd.arg("--check-cfg");
                cmd.arg(check_cfg);
            }
            for cfg in build_script_output.cfgs {
                cmd.arg("--cfg");
                cmd.arg(cfg);
            }
            for (key, val) in build_script_output.env {
                cmd.env(key, val);
            }

            cmd.env("OUT_DIR", build_script_dep.join("out"));
        }

        cmd.arg(target_path);

        // envs
        cmd.env("CARGO_CRATE_NAME", self.target.crate_name.as_ref())
            .env("CARGO_MANIFEST_DIR", self.src);

        if self.target.is_executable() {
            cmd.env("CARGO_BIN_NAME", self.target.name);
        }

        // TODO(phlip9): set `CARGO_BIN_EXE_` env for tests and benches

        // TODO(phlip9): set `CARGO_PRIMARY_PACKAGE=1` if we're a `-p` primary
        // workspace package target.

        // TODO(phlip9): set `CARGO_TARGET_TMPDIR` if test or bench unit

        // CARGO_PKG_<...> envs
        cmd.envs_cargo_pkg(self);

        trace!("{}", cmd.to_string_debug());

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

        // Query `rustc` for the cfgs it sets for this target triple. ~17 ms.
        // TODO(phlip9): cache this in a separate drv and pass in only to
        // custom-build targets.
        let rustc_target_cfgs = time!(
            "rustc --print cfg",
            RustcTargetCfg::collect(self.target_triple)
        );

        let mut cmd =
            Command::new(self.out.join(self.target.crate_name.as_ref()));
        cmd.current_dir(self.src)
            .stdout(File::create(self.out.join("output")).expect("$out/output"))
            .stderr(
                File::create(self.out.join("stderr")).expect("$out/stderr"),
            );

        let out_dir = self.out.join("out");
        fs::create_dir(&out_dir).expect("create_dir");

        let profile = &self.profile;
        let debug = profile.debuginfo != "0";

        // TODO(phlip9): `links`, `DEP_<name>_<key>`, `NUM_JOBS`, `RUSTC_LINKER`
        cmd.env("CARGO", "") // TODO
            .env("CARGO_CFG_PANIC", profile.panic)
            .env("CARGO_ENCODED_RUSTFLAGS", "")
            .env("CARGO_MAKEFLAGS", "") // TODO
            .env("CARGO_MANIFEST_DIR", self.src) // TODO(phlip9): incorrect for workspace
            .env("CARGO_MANIFEST_LINKS", "") // TODO
            .env("DEBUG", debug.to_string())
            .env("HOST", self.host_target_triple.as_ref().unwrap())
            .env("OPT_LEVEL", profile.opt_level.to_string())
            .env("OUT_DIR", &out_dir)
            .env("PROFILE", profile.name) // TODO(phlip9): should be base?
            .env("RUSTC", "rustc")
            .env("RUSTDOC", "rustdoc")
            .env("TARGET", self.target_triple);

        // rustc target cfg envs
        rustc_target_cfgs.env_cfgs(|env_key, env_value| {
            cmd.env(env_key, env_value);
        });

        // CARGO_PKG_<...> envs
        cmd.envs_cargo_pkg(self);

        // CARGO_FEATURE_<feature>=1 envs
        let mut feature_key = String::new();
        for feature in &self.target.features {
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

        trace!("{}", cmd.to_string_debug());

        let status = time!("run build_script_build", cmd.status())
            .expect("failed to run `$out/build_script_build`");
        if !status.success() {
            let code = status.code().unwrap_or(1);
            panic!("`$out/build_script_build` exited with non-zero exit code: {code}");
        }

        // TODO(phlip9): we should probably filter the stdout to only useful
        // output and log the rest.
    }

    /// Collect and symlink all deps' unique transitive deps into our
    /// `${out}/deps` dir. This dir will get passed as `-L ...` to `rustc` so it
    /// can locate transitive dep libs during compilation.
    ///
    /// TODO(phlip9): apparently nix builds can't hard link to other store paths
    /// (anymore?)? is this something I can get working again?
    fn collect_transitive_deps(&self) -> BTreeMap<OsString, &Dep> {
        let mut tdep_lib_filenames: BTreeMap<OsString, &Dep> = BTreeMap::new();

        // Nothing to collect
        if self.deps.is_empty() {
            return tdep_lib_filenames;
        }

        // Collect all the unique transitive dep libs from each `${dep}/deps`
        // directory.
        for dep in &self.deps {
            let dir_iter = match dep.out.join("deps").read_dir().ok() {
                Some(x) => x,
                None => continue,
            };

            let dep_tdep_lib_filenames = dir_iter.filter_map(|dir_entry| {
                let dir_entry = dir_entry.ok()?;
                let file_type = dir_entry.file_type().ok()?;
                (file_type.is_file() || file_type.is_symlink())
                    .then(|| dir_entry.file_name())
            });

            for dep_tdep_lib_filename in dep_tdep_lib_filenames {
                tdep_lib_filenames
                    .try_insert_stable(dep_tdep_lib_filename, dep);
            }
        }

        fs::create_dir(&self.out.join("deps")).expect("mkdir");

        // Symlink all our deps' transitive deps into our own `$out/deps` dir.

        // TODO(phlip9): place this in a tmpdir if we're a bin target (+etc)
        // that doesn't need to propagate?

        let mut link_src = PathBuf::new();
        let mut link_dst = PathBuf::new();

        for (tdep_lib_filename, dep) in &tdep_lib_filenames {
            // link_src = "${dep.out}/deps/${tdep_lib_filename}"
            link_src.clear();
            link_src.as_mut_os_string().push(dep.out);
            link_src.push("deps");
            link_src.push(tdep_lib_filename);

            let link_src_canon = link_src.canonicalize().expect("canonicalize");

            // link_dst = "${out}/deps/${tdep_lib_filename}"
            link_dst.clear();
            link_dst.as_mut_os_string().push(self.out);
            link_dst.push("deps");
            link_dst.push(tdep_lib_filename);

            fs::symlink(&link_src_canon, &link_dst).expect(
                "Failed to symlink transitive dep into our $out/deps dir",
            );
        }

        tdep_lib_filenames
    }

    /// After compilation, we'll collect our direct deps into our `$out/deps`
    /// dir. We do this after since we pass direct deps into compilation via
    /// precise `--extern <dep-name>=<lib-path>` args.
    fn collect_direct_deps(
        &self,
        tdep_lib_filenames: BTreeMap<OsString, &Dep>,
    ) {
        if self.deps.is_empty() {
            return;
        }

        // TODO(phlip9): skip if we're a bin target (+etc) that doesn't need to
        // propagate?

        let mut target = PathBuf::new();
        let mut symlink = PathBuf::new();

        for dep in &self.deps {
            // TODO(phlip9): how to handle multiple output libs?
            let dep_lib = dep.libs.first().unwrap();

            // skip deps that we've already linked from `collect_transitive_deps`
            if tdep_lib_filenames.contains_key(OsStr::new(&dep_lib)) {
                continue;
            }

            // link_src = "${dep.out}/${dep_lib}"
            target.clear();
            target.as_mut_os_string().push(dep.out);
            target.push(dep_lib);

            // link_dst = "${out}/deps/${dep_lib}"
            symlink.clear();
            symlink.as_mut_os_string().push(self.out);
            symlink.push("deps");
            symlink.push(dep_lib);

            fs::symlink(&target, &symlink)
                .expect("Failed to symlink direct dep into our $out/deps dir");
        }
    }
}

//
// --- impl Target ---
//

impl Target<'_> {
    fn is_lib(&self) -> bool {
        self.kind == TargetKind::Lib
    }

    fn is_dylib(&self) -> bool {
        self.is_lib()
            && (self.crate_types.iter().any(|x| *x == CrateType::Dylib))
    }

    // // TODO(phlip9): -C prefer-dynamic
    // fn is_cdylib(&self) -> bool {
    //     self.is_lib()
    //         && (self.crate_types.iter().any(|x| *x == CrateType::Cdylib))
    // }

    fn is_proc_macro(&self) -> bool {
        self.is_lib()
            && self.crate_types.iter().any(|x| *x == CrateType::ProcMacro)
    }

    fn is_executable(&self) -> bool {
        matches!(self.kind, TargetKind::Bin | TargetKind::ExampleBin)
    }

    fn is_custom_build(&self) -> bool {
        self.kind == TargetKind::CustomBuild
    }

    /// True if this target requires a `-C extra-filename=-{metadata-hash}` arg
    fn uses_extra_filename(&self) -> bool {
        // only lib targets
        // TODO(phlip9): no (dylib or cdylib) && path dep
        self.is_lib()
    }

    #[allow(dead_code)] // TODO(phlip9): remove
    fn requires_upstream_objects(&self) -> bool {
        match self.kind {
            TargetKind::Lib | TargetKind::ExampleLib => self
                .crate_types
                .iter()
                .any(CrateType::requires_upstream_objects),
            _ => true,
        }
    }

    /// True if this target type should propagate its deps (and transitive deps)
    /// to a dependent crate.
    fn propagates_deps(&self) -> bool {
        self.is_lib()
            && self.crate_types.iter().any(|x| {
                matches!(
                    *x,
                    CrateType::Lib | CrateType::Rlib | CrateType::Dylib
                )
            })
    }
}

//
// --- impl Dep ---
//

impl<'a> Dep<'a> {
    /// Read the dep's out dir for relevant .rlib, .so, ... output libs.
    fn from_cli(dep: cli::Dep<'a>) -> Self {
        let cli::Dep {
            dep_name,
            crate_name,
            out,
        } = dep;

        let mut libs = Vec::new();

        let dir_iter =
            std::fs::read_dir(out).expect("Failed to read dep directory");
        for dir_entry in dir_iter {
            let dir_entry = dir_entry.expect("Failed to read dep dir entry");
            if !dir_entry.file_type().unwrap().is_file() {
                continue;
            }
            let artifact = match dir_entry.file_name().into_string().ok() {
                Some(s) => s,
                None => continue,
            };
            if !artifact.contains(crate_name) {
                continue;
            }

            libs.push(artifact);
        }

        if libs.len() != 1 {
            panic!(
                "// TODO(phlip9): how to handle multiple output libs?\n\
                 libs: {libs:?}"
            );
        }

        Self {
            dep_name,
            crate_name,
            out,
            libs,
        }
    }

    fn lib_path(&self) -> PathBuf {
        // TODO(phlip9): how to handle multiple output libs?
        let lib = self.libs.first().unwrap();
        self.out.join(lib)
    }
}

//
// --- impl CommandExt ---
//

trait CommandExt {
    fn to_string_debug(&self) -> String;
    fn envs_cargo_pkg(&mut self, ctx: &BuildContext) -> &mut Self;
}

impl CommandExt for Command {
    /// Serialize the `Command` as a human-readable string that you can run in a
    /// shell.
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
            out.push_str(&shell::escape(&val));
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
            out.push_str(&shell::escape(&arg));

            let is_opt = arg.starts_with('-');
            if is_opt {
                let is_next_opt =
                    args.peek().map(|arg| arg.starts_with('-')).unwrap_or(true);

                if !is_next_opt {
                    let next_arg = args.next().expect("Must be Some");
                    out.push(' ');
                    out.push_str(&shell::escape(&next_arg));
                }
            }

            if args.peek().is_some() {
                out.push_str(" \\\n");
            } else {
                out.push('\n');
            }
        }

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
            .env("CARGO_PKG_NAME", ctx.pkg_name)
            .env("CARGO_PKG_README", "") // TODO
            .env("CARGO_PKG_REPOSITORY", "") // TODO
            .env("CARGO_PKG_RUST_VERSION", "") // TODO
            .env("CARGO_PKG_VERSION", target.version.as_str())
            .env("CARGO_PKG_VERSION_MAJOR", target.version.major())
            .env("CARGO_PKG_VERSION_MINOR", target.version.minor())
            .env("CARGO_PKG_VERSION_PATCH", target.version.patch())
            .env("CARGO_PKG_VERSION_PRE", target.version.pre().unwrap_or(""))
    }
}

//
// --- impl BTreeMapExt ---
//

trait BTreeMapExt<K, V> {
    /// Try to insert `key` -> `value` into the `BTreeMap`. Returns `true` if
    /// it was actually inserted (because `key` was not already in the map).
    fn try_insert_stable(&mut self, key: K, value: V) -> bool;
}

impl<K: Ord, V> BTreeMapExt<K, V> for BTreeMap<K, V> {
    fn try_insert_stable(&mut self, key: K, value: V) -> bool {
        use std::collections::btree_map::Entry;
        match self.entry(key) {
            Entry::Occupied(_) => false,
            Entry::Vacant(entry) => {
                entry.insert(value);
                true
            }
        }
    }
}
