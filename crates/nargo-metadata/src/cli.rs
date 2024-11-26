use std::path::{Path, PathBuf};

use nargo_core::{fs, time};

use crate::run;

const HELP: &str = r#"
nargo-metadata

USAGE:
  nargo-metadata [OPTIONS]

FLAGS:
  -h, --help
      Prints help information

  -V, --version
      Prints version

OPTIONS:
  --input-raw-metadata PATH
      Path to the raw `cargo metadata` json output. If left unset or set to "-",
      then this is read from stdin.

  --input-current-metadata PATH
      Path to the current `Cargo.metadata.json`, if it exists. If left unset,
      then we'll try to read it from the current directory.

  --output-metadata PATH
      Path to output the new `Cargo.metadata.json`. If set to "-", then this is
      written to stdout.

  --nix-prefetch
      Prefetch and pin dependencies from crates.io using `nix store prefetch-file`.
      Does not work inside the `nix build` sandbox.

  --assume-vendored
      Assume all external crate paths in the `--input-raw-metadata` are already
      vendored in the /nix/store, so we can reuse them.

      Typically used when run inside the `nix build` sandbox, where the crates
      are already vendored using something like `crane.vendorCargoDeps`.
"#;

const VERSION: &str =
    concat!(env!("CARGO_PKG_NAME"), " ", env!("CARGO_PKG_VERSION"), "\n");

pub struct Args {
    input_raw_metadata: Option<PathBuf>,
    input_current_metadata: Option<PathBuf>,
    output_metadata: Option<PathBuf>,
    nix_prefetch: bool,
    assume_vendored: bool,
}

impl Args {
    pub fn from_env() -> Result<Self, lexopt::Error> {
        use lexopt::prelude::*;

        let mut input_raw_metadata: Option<PathBuf> = None;
        let mut input_current_metadata: Option<PathBuf> = None;
        let mut output_metadata: Option<PathBuf> = None;
        let mut nix_prefetch = false;
        let mut assume_vendored = false;

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
                Long("input-raw-metadata") if input_raw_metadata.is_none() => {
                    input_raw_metadata = Some(PathBuf::from(parser.value()?));
                }
                Long("input-current-metadata")
                    if input_current_metadata.is_none() =>
                {
                    input_current_metadata =
                        Some(PathBuf::from(parser.value()?));
                }
                Long("output-metadata") if output_metadata.is_none() => {
                    output_metadata = Some(PathBuf::from(parser.value()?));
                }
                Long("nix-prefetch") if !nix_prefetch => {
                    nix_prefetch = true;
                }
                Long("assume-vendored") if !assume_vendored => {
                    assume_vendored = true;
                }
                _ => return Err(arg.unexpected()),
            }
        }

        Ok(Args {
            input_raw_metadata,
            input_current_metadata,
            output_metadata,
            nix_prefetch,
            assume_vendored,
        })
    }

    pub fn run(self) {
        let input_raw_metadata_bytes = time!(
            "read `cargo metadata` output",
            fs::read_file_or_stdin(self.input_raw_metadata.as_deref())
                .expect("Failed to read `cargo metadata` output")
        );

        let input_current_metadata = self
            .input_current_metadata
            .as_deref()
            .unwrap_or(Path::new("Cargo.metadata.json"));
        let input_current_metadata_bytes = time!(
            "read current Cargo.metadata.json",
            fs::read_file(input_current_metadata)
                .expect("Failed to read current `Cargo.metadata.json`")
        );

        let args = run::Args {
            input_raw_metadata_bytes: input_raw_metadata_bytes.as_slice(),
            input_current_metadata_bytes: input_current_metadata_bytes
                .as_deref(),
            output_metadata: self.output_metadata.as_deref(),
            nix_prefetch: self.nix_prefetch,
            assume_vendored: self.assume_vendored,
        };

        time!("run", run::run(args));
    }
}
