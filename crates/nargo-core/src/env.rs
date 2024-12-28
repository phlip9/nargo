use std::{
    error::Error,
    ffi::{OsStr, OsString},
    fmt,
};

/// Like [`std::env::var_os`] but includes the env var key in the error for
/// better error messages.
pub fn var_os(key: &str) -> Result<OsString, VarError<'_>> {
    std::env::var_os(OsStr::new(key)).ok_or(VarError {
        kind: VarErrorKind::Missing,
        key,
    })
}

pub fn var(key: &str) -> Result<String, VarError<'_>> {
    std::env::var(OsStr::new(key)).map_err(|err| {
        let kind = match err {
            std::env::VarError::NotPresent => VarErrorKind::Missing,
            std::env::VarError::NotUnicode(_) => VarErrorKind::NotUtf8,
        };
        VarError { kind, key }
    })
}

pub struct VarError<'a> {
    kind: VarErrorKind,
    key: &'a str,
}

pub enum VarErrorKind {
    Missing,
    NotUtf8,
}

//
// --- impl VarError ---
//

impl Error for VarError<'_> {}

impl fmt::Display for VarError<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self.kind {
            VarErrorKind::Missing => "missing env var: ",
            VarErrorKind::NotUtf8 => "env var is not valid UTF-8: ",
        };
        f.write_str(s)?;
        f.write_str(self.key)
    }
}
impl fmt::Debug for VarError<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}
