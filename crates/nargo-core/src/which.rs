use std::{
    env,
    ffi::OsStr,
    path::{Path, PathBuf},
};

/// Locate a binary in `$PATH`, like coreutils `which`.
pub fn which<T: AsRef<Path>>(bin_name: T) -> Option<PathBuf> {
    which_inner(bin_name.as_ref(), &env::var_os("PATH")?)
}

#[inline]
fn which_inner(bin_name: &Path, path_env: &OsStr) -> Option<PathBuf> {
    env::split_paths(path_env)
        .filter_map(|mut bin_path| {
            bin_path.push(bin_name);
            if bin_path.is_file() {
                Some(bin_path)
            } else {
                None
            }
        })
        .next()
}

#[cfg(test)]
mod test {
    use super::*;

    #[ignore]
    #[test]
    fn test_which() {
        which("cargo").unwrap();
        assert_eq!(None, which("cargoooaosidjfoiasdjf"));
    }
}
