use std::{
    fs,
    io::{self, Read},
    path::Path,
};

use anyhow::Context;

/// Raw `cargo` json output can be fairly large (a few MiB). To avoid too
/// many realloc's while reading stdin, we'll make an initial size guess of
/// 512 KiB.
const INIT_SIZE_GUESS: usize = 512 << 10;

pub fn read_file_or_stdin(path: Option<&Path>) -> anyhow::Result<Vec<u8>> {
    match path {
        None => read_stdin(),
        Some(path) if path == Path::new("-") => read_stdin().context("<stdin>"),
        Some(path) =>
            read_file(path).with_context(|| path.to_string_lossy().into_owned()),
    }
}

pub fn read_file(path: &Path) -> anyhow::Result<Vec<u8>> {
    let mut file = fs::OpenOptions::new().read(true).open(path)?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(buf)
}

fn read_stdin() -> anyhow::Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(INIT_SIZE_GUESS);
    let mut stdin = io::stdin().lock();
    stdin.read_to_end(&mut buf)?;
    Ok(buf)
}
