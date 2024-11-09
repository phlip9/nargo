use std::{ffi::OsStr, path::PathBuf};

use nargo_core::{fs, time};

const HELP: &str = r#"
nargo-resolve

USAGE:
  nargo-resolve --unit-graph PATH --nargo-resolve PATH --host-target TARGET
                --workspace-root PATH

FLAGS:
  -h, --help                Prints help information

OPTIONS:
  --unit-graph PATH         Path to `cargo build --unit-graph` json file.
  --resolve-features PATH   Path to json output of `nix eval` of `resolveFeatures`.
  --host-target TARGET      The --target triple of the `cargo build` invocation.
  --workspace-root PATH     Path to cargo workspace root directory.
"#;

pub struct Args {
    unit_graph: PathBuf,
    resolve_features: PathBuf,
    host_target: String,
    workspace_root: String,
}

impl Args {
    pub fn from_env() -> Result<Self, pico_args::Error> {
        let mut pargs = pico_args::Arguments::from_env();

        if pargs.contains(["-h", "--help"]) {
            eprint!("{HELP}");
            std::process::exit(0);
        }

        let args = Args {
            unit_graph: pargs.value_from_os_str("--unit-graph", parse_path)?,
            resolve_features: pargs
                .value_from_os_str("--resolve-features", parse_path)?,
            host_target: pargs.value_from_str("--host-target")?,
            workspace_root: pargs.value_from_str("--workspace-root")?,
        };

        Ok(args)
    }

    pub fn run(self) {
        let unit_graph_buf = time!(
            "read --unit-graph",
            fs::read_existing_file(&self.unit_graph)
                .expect("Failed to read `--unit-graph`")
        );

        let resolve_features_buf = time!(
            "read --resolve-features",
            fs::read_existing_file(&self.resolve_features)
                .expect("Failed to read `--resolve-features`"),
        );

        time!(
            "run",
            crate::run::run(
                &unit_graph_buf,
                &resolve_features_buf,
                &self.host_target,
                &self.workspace_root,
            )
        );
    }
}

fn parse_path(os_str: &OsStr) -> Result<PathBuf, pico_args::Error> {
    Ok(PathBuf::from(os_str))
}
