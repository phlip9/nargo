use std::path::PathBuf;

use nargo_core::{fs, time};

const HELP: &str = r#"
nargo-resolve

USAGE:
  nargo-resolve --unit-graph PATH --nargo-resolve PATH --host-target TARGET
                --workspace-root PATH

FLAGS:
  -h, --help                Prints help information
  -V, --version             Prints version

OPTIONS:
  --unit-graph PATH         Path to `cargo build --unit-graph` json file.
  --resolve-features PATH   Path to json output of `nix eval` of `resolveFeatures`.
  --host-target TARGET      The --target triple of the `cargo build` invocation.
  --workspace-root PATH     Path to cargo workspace root directory.
"#;

const VERSION: &str =
    concat!(env!("CARGO_PKG_NAME"), " ", env!("CARGO_PKG_VERSION"), "\n");

pub struct Args {
    unit_graph: PathBuf,
    resolve_features: PathBuf,
    host_target: String,
    workspace_root: String,
}

impl Args {
    pub fn from_env() -> Result<Self, lexopt::Error> {
        use lexopt::prelude::*;

        let mut unit_graph: Option<PathBuf> = None;
        let mut resolve_features: Option<PathBuf> = None;
        let mut host_target: Option<String> = None;
        let mut workspace_root: Option<String> = None;

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
                Long("unit-graph") if unit_graph.is_none() => {
                    unit_graph = Some(PathBuf::from(parser.value()?));
                }
                Long("resolve-features") if resolve_features.is_none() => {
                    resolve_features = Some(PathBuf::from(parser.value()?));
                }
                Long("host-target") if host_target.is_none() => {
                    host_target = Some(parser.value()?.string()?);
                }
                Long("workspace-root") if workspace_root.is_none() => {
                    workspace_root = Some(parser.value()?.string()?);
                }
                _ => return Err(arg.unexpected()),
            }
        }

        Ok(Args {
            unit_graph: unit_graph.ok_or("missing --unit-graph")?,
            resolve_features: resolve_features
                .ok_or("missing --resolve-features")?,
            host_target: host_target.ok_or("missing --host-target")?,
            workspace_root: workspace_root.ok_or("missing --workspace-root")?,
        })
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
