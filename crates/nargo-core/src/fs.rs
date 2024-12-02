use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use anyhow::Context;

/// Raw `cargo` json output can be fairly large (a few MiB). To avoid too
/// many realloc's while reading stdin, we'll make an initial size guess of
/// 512 KiB.
const INIT_SIZE_GUESS: usize = 512 << 10;

fn path_ctx(path: &Path) -> Box<str> {
    path.to_string_lossy().into()
}

fn link_ctx(target: &Path, symlink: &Path) -> Box<str> {
    format!("{} -> {}", symlink.display(), target.display()).into()
}

// --- read --- //

pub fn read_file_or_stdin(path: Option<&Path>) -> anyhow::Result<Vec<u8>> {
    match path {
        None => read_stdin(),
        Some(path) if path == Path::new("-") => read_stdin(),
        Some(path) => read_existing_file(path).with_context(|| path_ctx(path)),
    }
}

pub fn read_existing_file(path: &Path) -> anyhow::Result<Vec<u8>> {
    read_file_inner(path)
        .and_then(|opt_file| {
            opt_file.ok_or(io::Error::from(io::ErrorKind::NotFound))
        })
        .with_context(|| path_ctx(path))
}

pub fn read_file(path: &Path) -> anyhow::Result<Option<Vec<u8>>> {
    read_file_inner(path).with_context(|| path_ctx(path))
}

fn read_file_inner(path: &Path) -> io::Result<Option<Vec<u8>>> {
    let mut file = match fs::OpenOptions::new().read(true).open(path) {
        Ok(ok) => ok,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err),
    };
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(Some(buf))
}

fn read_stdin() -> anyhow::Result<Vec<u8>> {
    // `stdin` doesn't know how large the input is, so we have to guess.
    let mut buf = Vec::with_capacity(INIT_SIZE_GUESS);
    let mut stdin = io::stdin().lock();
    stdin.read_to_end(&mut buf).context("<stdin>")?;
    Ok(buf)
}

// --- write --- //

pub fn write_file_or_stdout(
    path: Option<&Path>,
    buf: &[u8],
) -> anyhow::Result<()> {
    match path {
        None => write_stdout(buf),
        Some(path) if path == Path::new("-") => write_stdout(buf),
        Some(path) => write_file(path, buf),
    }
}

pub fn write_file(path: &Path, buf: &[u8]) -> anyhow::Result<()> {
    fs::write(path, buf).with_context(|| path_ctx(path))
}

pub fn write_stdout(buf: &[u8]) -> anyhow::Result<()> {
    let mut stdout = io::stdout().lock();
    stdout
        .write_all(buf)
        .and_then(|_| stdout.flush())
        .context("<stdout>")
}

// --- mkdir --- //

pub fn create_dir(path: &Path) -> anyhow::Result<()> {
    fs::create_dir(path).with_context(|| path_ctx(path))
}

// --- link --- //

// pub fn hard_link(target: &Path, link: &Path) -> anyhow::Result<()> {
//     fs::hard_link(target, link).with_context(|| link_ctx(target, link))
// }

/// Create a symlink file `symlink` -- pointing at --> a `target` path.
pub fn symlink(target: &Path, symlink: &Path) -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, symlink)
            .with_context(|| link_ctx(target, symlink))
    }
    #[cfg(not(unix))]
    {
        panic!("TODO(phlip9): symlink not supported yet on this platform?")
    }
}

pub fn canonicalize(path: &Path) -> anyhow::Result<PathBuf> {
    fs::canonicalize(path).with_context(|| path_ctx(path))
}
