use std::{ffi::OsStr, path::PathBuf};

use nargo_core::{fs, time};

const HELP: &str = r#"
nargo-resolve

USAGE:
  nargo-resolve [--unit-graph UNITGRAPH]

FLAGS:
  -h, --help              Prints help information

OPTIONS:
  --unit-graph UNITGRAPH  Path to `cargo build --unit-graph` json output. If
                          left unset or set to "-", then this is read from
                          stdin.
"#;

pub struct Args {
    unit_graph: Option<PathBuf>,
}

impl Args {
    pub fn from_env() -> Result<Self, pico_args::Error> {
        let mut pargs = pico_args::Arguments::from_env();

        if pargs.contains(["-h", "--help"]) {
            eprint!("{HELP}");
            std::process::exit(0);
        }

        let args = Args {
            unit_graph: pargs
                .opt_value_from_os_str("--unit-graph", parse_path)?,
        };

        Ok(args)
    }

    pub fn run(self) {
        let buf = time!(
            "read input",
            fs::read_file_or_stdin(self.unit_graph.as_deref())
                .expect("Failed to read `cargo metadata`")
        );

        time!("run", crate::run(buf.as_slice()));
    }
}

fn parse_path(os_str: &OsStr) -> Result<PathBuf, pico_args::Error> {
    Ok(PathBuf::from(os_str))
}
