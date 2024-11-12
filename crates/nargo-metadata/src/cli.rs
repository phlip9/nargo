use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
};

use nargo_core::{fs, time};

use crate::run;

const HELP: &str = r#"
nargo-metadata

USAGE:
  nargo-metadata [OPTIONS]

FLAGS:
  -h, --help
      Prints help information

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

pub struct Args {
    input_raw_metadata: Option<PathBuf>,
    input_current_metadata: Option<PathBuf>,
    output_metadata: Option<PathBuf>,
    nix_prefetch: bool,
    assume_vendored: bool,
}

impl Args {
    pub fn from_env() -> Result<Self, pico_args::Error> {
        let mut pargs = pico_args::Arguments::from_env();

        if pargs.contains(["-h", "--help"]) {
            eprint!("{HELP}");
            std::process::exit(0);
        }

        let args = Args {
            input_raw_metadata: pargs
                .opt_value_from_os_str("--input-raw-metadata", parse_path)?,
            input_current_metadata: pargs.opt_value_from_os_str(
                "--input-current-metadata",
                parse_path,
            )?,
            output_metadata: pargs
                .opt_value_from_os_str("--output-metadata", parse_path)?,
            nix_prefetch: pargs.contains("--nix-prefetch"),
            assume_vendored: pargs.contains("--assume-vendored"),
        };

        Ok(args)
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

fn parse_path(os_str: &OsStr) -> Result<PathBuf, pico_args::Error> {
    Ok(PathBuf::from(os_str))
}
