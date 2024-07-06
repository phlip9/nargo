use std::{
    ffi::OsStr,
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
};

/// Raw `cargo metadata` output can be fairly large (a few MiB). To avoid too
/// many realloc's while reading stdin, we'll make an initial size guess of
/// 512 KiB.
const INIT_SIZE_GUESS: usize = 512 << 10;

const HELP: &str = r#"
nargo-metadata

USAGE:
  nargo-metadata [OPTIONS] --src SRC

FLAGS:
  -h, --help            Prints help information

OPTIONS:
  --src SRC             Cargo workspace directory path
  --metadata METADATA   Path to raw cargo-metadata json output. If left unset
                        or set to "-", then we read from stdin.
"#;

pub struct Args {
    src: String,
    metadata: Option<PathBuf>,
}

impl Args {
    pub fn from_env() -> Result<Self, pico_args::Error> {
        let mut pargs = pico_args::Arguments::from_env();

        if pargs.contains(["-h", "--help"]) {
            eprint!("{HELP}");
            std::process::exit(0);
        }

        let args = Args {
            src: pargs.value_from_fn("--src", parse_str)?,
            metadata: pargs.opt_value_from_os_str("--metadata", parse_path)?,
        };

        Ok(args)
    }

    pub fn run(self) {
        let buf = time!(
            "read input",
            read_file_or_stdin(self.metadata.as_deref())
                .expect("Failed to read `cargo metadata`")
        );

        // eprintln!("{}", std::str::from_utf8(&buf[..50]).unwrap());

        time!("run", crate::run::run(&self.src, buf.as_slice()));
    }
}

fn parse_str(s: &str) -> Result<String, pico_args::Error> {
    Ok(s.to_owned())
}

fn parse_path(os_str: &OsStr) -> Result<PathBuf, pico_args::Error> {
    Ok(PathBuf::from(os_str))
}

fn read_file_or_stdin(path: Option<&Path>) -> io::Result<Vec<u8>> {
    match path {
        None => read_stdin(),
        Some(path) if path == Path::new("-") => read_stdin(),
        Some(path) => read_file(path),
    }
}

fn read_file(path: &Path) -> io::Result<Vec<u8>> {
    let mut file = fs::OpenOptions::new().read(true).open(path)?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(buf)
}

fn read_stdin() -> io::Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(INIT_SIZE_GUESS);
    let mut stdin = io::stdin().lock();
    stdin.read_to_end(&mut buf)?;
    Ok(buf)
}
