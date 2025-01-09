use std::{
    path::{Path, PathBuf},
    process::Command,
};

use nargo_core::{fs, logger, time};

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

  -v, --verbose
      Verbose logging

OPTIONS:
  --input-raw-metadata PATH
      Path to the raw `cargo metadata` json output. If set to "-", then this is
      read from stdin. If left unset, we'll call `cargo metadata` directly.

  --input-manifest-path PATH
      Path to `Cargo.toml` manifest. Only used if `--input-raw-metadata` is unset.

  --input-current-metadata PATH
      Path to the current `Cargo.metadata.json`, if it exists. If left unset,
      then we'll try to read it from the current directory.

  --output-metadata PATH
      Path to output the new `Cargo.metadata.json`. If set to "-", then this is
      written to stdout. If left unset, we'll default to `Cargo.metadata.json`
      in the current directory.

  --no-nix-prefetch
      By default, we prefetch and pin dependencies from crates.io using
      `nix store prefetch-file`. Set this flag to disable prefetching, as it
      doesn't work inside the `nix build` sandbox.

  --assume-vendored
      Assume all external crate paths in the `--input-raw-metadata` are already
      vendored in the /nix/store, so we can reuse them.

      Typically used when run inside the `nix build` sandbox, where the crates
      are already vendored using something like `crane.vendorCargoDeps`.

  --check
      Generate the new `Cargo.metadata.json` but don't write it. Instead just
      check that it matches the current `Cargo.metadata.json`.
"#;

const VERSION: &str =
    concat!(env!("CARGO_PKG_NAME"), " ", env!("CARGO_PKG_VERSION"), "\n");

pub struct Args {
    input_raw_metadata: Option<PathBuf>,
    input_manifest_path: Option<PathBuf>,
    input_current_metadata: Option<PathBuf>,
    output_metadata: Option<PathBuf>,
    no_nix_prefetch: bool,
    assume_vendored: bool,
    check: bool,
}

impl Args {
    pub fn from_env() -> Result<Self, lexopt::Error> {
        use lexopt::prelude::*;

        let mut input_raw_metadata: Option<PathBuf> = None;
        let mut input_manifest_path: Option<PathBuf> = None;
        let mut input_current_metadata: Option<PathBuf> = None;
        let mut output_metadata: Option<PathBuf> = None;
        let mut no_nix_prefetch = false;
        let mut assume_vendored = false;
        let mut check = false;

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
                Short('v') | Long("verbose") => {
                    logger::set_level(logger::Level::Trace);
                }
                Long("input-raw-metadata") if input_raw_metadata.is_none() => {
                    input_raw_metadata = Some(PathBuf::from(parser.value()?));
                }
                Long("input-manifest-path")
                    if input_manifest_path.is_none() =>
                {
                    input_manifest_path = Some(PathBuf::from(parser.value()?));
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
                Long("no-nix-prefetch") if !no_nix_prefetch => {
                    no_nix_prefetch = true;
                }
                Long("assume-vendored") if !assume_vendored => {
                    assume_vendored = true;
                }
                Long("check") if !check => {
                    check = true;
                }
                _ => return Err(arg.unexpected()),
            }
        }

        Ok(Args {
            input_raw_metadata,
            input_manifest_path,
            input_current_metadata,
            output_metadata,
            no_nix_prefetch,
            assume_vendored,
            check,
        })
    }

    pub fn run(self) {
        // Run `cargo metadata` or read from an existing file/stdin.
        let input_raw_metadata_bytes = self.read_input_raw_metadata();

        // Read existing `Cargo.metadata.json` if it exists (from previous
        // nargo-metadata output). We'll use this if we need to nix-prefetch.
        let input_current_metadata = self
            .input_current_metadata
            .as_deref()
            .unwrap_or(Path::new("Cargo.metadata.json"));
        let input_current_metadata_bytes = time!(
            "read current Cargo.metadata.json",
            fs::read_file(input_current_metadata)
                .expect("Failed to read current `Cargo.metadata.json`")
        );

        let output_metadata = self
            .output_metadata
            .as_deref()
            .unwrap_or(Path::new("Cargo.metadata.json"));

        let args = run::Args {
            input_raw_metadata_bytes: input_raw_metadata_bytes.as_slice(),
            input_current_metadata_bytes: input_current_metadata_bytes
                .as_deref(),
            output_metadata,
            nix_prefetch: !self.no_nix_prefetch,
            assume_vendored: self.assume_vendored,
            check: self.check,
        };

        time!("run", run::run(args));
    }

    /// Run `cargo metadata` or read from an existing file/stdin.
    fn read_input_raw_metadata(&self) -> Vec<u8> {
        // If `--input-raw-metadata` is set, read from it (file/stdin).
        if let Some(path) = self.input_raw_metadata.as_deref() {
            return time!(
                "read `cargo metadata` output file",
                fs::read_file_or_stdin(Some(path)).expect(
                    "Failed to read file containing `cargo metadata` output",
                ),
            );
        }

        // Else, call `cargo metadata` directly
        // $ cargo metadata \
        //   --frozen \
        //   --format-version=1 \
        //   --all-features
        let mut cmd = Command::new("cargo");
        cmd.args([
            "metadata",
            "--frozen",
            "--format-version=1",
            "--all-features",
        ]);

        // --manifest-path ${self.input_manifest_path}
        if let Some(manifest_path) = self.input_manifest_path.as_deref() {
            cmd.arg("--manifest-path");
            cmd.arg(manifest_path);
        }

        let output = time!(
            "run `cargo metadata`",
            cmd.output().expect("Failed to run `cargo`")
        );

        if !output.status.success() {
            let code = output.status.code().unwrap_or(1);
            panic!(
                "`cargo metadata` failed with exit code: {code}\n\
                 \n\
                 > stdout:\n\
                 {}\n\
                 \n\
                 > stderr: \n\
                 {}\n\
                 ",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
            );
        }

        output.stdout
    }
}
