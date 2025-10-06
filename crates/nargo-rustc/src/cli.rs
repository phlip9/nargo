use std::{
    ffi::{OsStr, OsString},
    path::Path,
    str::FromStr,
};

use crate::{run, semver};
use nargo_core::{env, logger, trace};

pub struct ArgsRaw {
    pub(crate) build_script_dep: OsString,
    pub(crate) crate_type: String,
    pub(crate) dep_crate_names: String,
    pub(crate) dep_names: String,
    pub(crate) dep_paths: OsString,
    pub(crate) edition: String,
    pub(crate) features: String,
    pub(crate) kind: String,
    pub(crate) log: String,
    pub(crate) out: OsString,
    pub(crate) pkg_name: String,
    pub(crate) src: OsString,
    pub(crate) target_name: String,
    pub(crate) target_path: OsString,
    pub(crate) target_triple: String,
    pub(crate) version: String,
}

#[derive(Debug)] // TODO(phlip9): remove
pub struct Args<'a> {
    pub(crate) build_script_dep: Option<&'a Path>,
    pub(crate) crate_type: &'a str,
    pub(crate) deps: Vec<Dep<'a>>,
    pub(crate) edition: &'a str,
    pub(crate) features: &'a str,
    pub(crate) kind: &'a str,
    pub(crate) log: logger::Level,
    pub(crate) out: &'a Path,
    pub(crate) pkg_name: &'a str,
    pub(crate) src: &'a Path,
    pub(crate) target_name: &'a str,
    pub(crate) target_path: &'a Path,
    pub(crate) target_triple: &'a str,
    pub(crate) version: semver::Version<'a>,
}

#[derive(Debug)] // TODO(phlip9): remove
pub struct Dep<'a> {
    pub(crate) crate_name: &'a str,
    pub(crate) dep_name: &'a str,
    pub(crate) out: &'a Path,
}

impl ArgsRaw {
    pub fn from_env() -> Self {
        Self {
            build_script_dep: env::var_os("BUILD_SCRIPT_DEP").unwrap(),
            crate_type: env::var("CRATE_TYPE").unwrap(),
            dep_names: env::var("DEP_NAMES").unwrap(),
            dep_crate_names: env::var("DEP_CRATE_NAMES").unwrap(),
            dep_paths: env::var_os("DEP_PATHS").unwrap(),
            edition: env::var("EDITION").unwrap(),
            features: env::var("FEATURES").unwrap(),
            kind: env::var("KIND").unwrap(),
            log: env::var("LOG").unwrap(),
            out: env::var_os("out").unwrap(),
            pkg_name: env::var("PKG_NAME").unwrap(),
            src: env::var_os("src").unwrap(),
            target_name: env::var("TARGET_NAME").unwrap(),
            target_path: env::var_os("TARGET_PATH").unwrap(),
            target_triple: env::var("TARGET_TRIPLE").unwrap(),
            version: env::var("version").unwrap(),
        }
    }

    /// Clear all nargo-specific envs.
    ///
    /// # Safety
    ///
    /// [`std::env::remove_var`] is not thread-safe. You must call this before
    /// spawning any threads.
    pub unsafe fn remove_nargo_envs() {
        const REMOVE_ENVS: &[&str] = &[
            "BUILD_SCRIPT_DEP",
            "CRATE_TYPE",
            "DEP_NAMES",
            "DEP_CRATE_NAMES",
            "DEP_PATHS",
            "EDITION",
            "FEATURES",
            "KIND",
            "LOG",
            "out",
            "PKG_NAME",
            "src",
            "TARGET_NAME",
            "TARGET_PATH",
            "TARGET_TRIPLE",
            "version",
        ];

        for env in REMOVE_ENVS {
            unsafe {
                std::env::remove_var(env);
            }
        }
    }
}

impl<'a> Args<'a> {
    pub fn from_raw(args: &'a ArgsRaw) -> Self {
        let build_script_dep = if args.build_script_dep.is_empty() {
            None
        } else {
            Some(Path::new(&args.build_script_dep))
        };

        let version = args.version.as_str();
        let version =
            semver::Version::from_str(version).expect("`version` env");

        let log = logger::Level::from_str(&args.log).expect("invalid LOG env");

        Self {
            build_script_dep,
            crate_type: &args.crate_type,
            deps: parse_deps(
                &args.dep_names,
                &args.dep_crate_names,
                &args.dep_paths,
            ),
            edition: &args.edition,
            features: &args.features,
            kind: &args.kind,
            log,
            out: Path::new(&args.out),
            pkg_name: &args.pkg_name,
            src: Path::new(&args.src),
            target_name: &args.target_name,
            target_path: Path::new(&args.target_path),
            target_triple: &args.target_triple,
            version,
        }
    }

    pub fn run(self) {
        logger::set_level(self.log);

        // Show package name and target kind in perf traces.
        set_process_perf_label(&self);

        trace!("args: {self:#?}");

        run::BuildContext::from_args(self).run()
    }

    pub fn label(&self) -> String {
        let pkg_name = self.pkg_name;
        let version = &self.version;
        let kind = self.kind;
        format!("{pkg_name}-{version}-{kind}")
    }
}

fn parse_deps<'a>(
    dep_names: &'a str,
    dep_crate_names: &'a str,
    dep_paths: &'a OsStr,
) -> Vec<Dep<'a>> {
    if dep_names.is_empty()
        && dep_crate_names.is_empty()
        && dep_paths.is_empty()
    {
        return Vec::new();
    }

    assert!(
        !dep_names.is_empty()
            && !dep_crate_names.is_empty()
            && !dep_paths.is_empty()
    );

    let mut dep_names = dep_names.split(' ');
    let mut dep_crate_names = dep_crate_names.split(' ');
    let mut dep_paths = dep_paths.as_encoded_bytes().split(|b| *b == b' ');

    let mut deps = Vec::new();

    loop {
        match (dep_names.next(), dep_crate_names.next(), dep_paths.next()) {
            (Some(dep_name), Some(crate_name), Some(path)) => {
                #[cfg(unix)]
                let path =
                    <OsStr as std::os::unix::ffi::OsStrExt>::from_bytes(path);

                #[cfg(not(unix))]
                let path = todo!();

                deps.push(Dep {
                    dep_name,
                    crate_name,
                    out: Path::new(path),
                });
            }
            (None, None, None) => break deps,
            _ => panic!("DEP_NAMES, DEP_CRATE_NAMES, and DEP_PATHS are uneven"),
        };
    }
}

/// (Linux) Improve perf trace readability by setting the process `comm` value
/// to include the package name and target kind.
fn set_process_perf_label(args: &Args<'_>) {
    #[cfg(target_os = "linux")]
    {
        // /proc/self/comm truncates after 15 B, so we have to be a bit creative
        use std::str::FromStr;
        let kind = nargo_core::nargo::TargetKind::from_str(args.kind)
            .expect("Invalid target kind")
            .to_debug_char();
        let package = args.pkg_name;
        let comm = format!("nr {kind} {package}");
        std::fs::write("/proc/self/comm", comm.as_bytes()).unwrap();
    }
}
