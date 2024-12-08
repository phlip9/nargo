//! Lightweight `anyhow`

use std::convert::Infallible;
use std::error::Error as StdError;
use std::fmt;

pub type Result<T, E = Error> = std::result::Result<T, E>;

// TODO(phlip9): maybe one day this can be a thin pointer String
#[allow(clippy::box_collection)] // It's important this only takes 1 word
#[repr(transparent)]
pub struct Error(pub Box<String>);

pub trait Context<T, E> {
    fn context(self, context: impl fmt::Display) -> Result<T>;

    fn with_context<C, F>(self, context: F) -> Result<T>
    where
        C: fmt::Display,
        F: FnOnce() -> C;
}

//
// --- impl Error ---
//

impl Error {
    pub fn from_display(err: impl fmt::Display) -> Self {
        Self(Box::new(err.to_string()))
    }
}

// ensure `Error` is pointer sized
const _: [(); std::mem::size_of::<*const ()>()] =
    [(); std::mem::size_of::<Error>()];

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl<E: StdError> From<E> for Error {
    #[cold]
    fn from(value: E) -> Self {
        Self(Box::new(value.to_string()))
    }
}

//
// --- impl Context ---
//

impl<T, E> Context<T, E> for Result<T, E>
where
    E: ExtContext,
{
    fn context(self, context: impl fmt::Display) -> Result<T> {
        match self {
            Ok(ok) => Ok(ok),
            Err(err) => Err(err.ext_context(context)),
        }
    }

    fn with_context<C, F>(self, context: F) -> Result<T>
    where
        C: fmt::Display,
        F: FnOnce() -> C,
    {
        match self {
            Ok(ok) => Ok(ok),
            Err(err) => Err(err.ext_context(context())),
        }
    }
}

impl<T> Context<T, Infallible> for Option<T> {
    fn context(self, context: impl fmt::Display) -> Result<T> {
        match self {
            Some(ok) => Ok(ok),
            None => Err(Error::from_display(context)),
        }
    }

    fn with_context<C, F>(self, context: F) -> Result<T>
    where
        C: fmt::Display,
        F: FnOnce() -> C,
    {
        match self {
            Some(ok) => Ok(ok),
            None => Err(Error::from_display(context())),
        }
    }
}

trait ExtContext {
    fn ext_context(self, context: impl fmt::Display) -> Error;
}

impl ExtContext for Error {
    fn ext_context(self, context: impl fmt::Display) -> Error {
        ext_context_inner(context.to_string(), &self.0)
    }
}

#[inline(never)]
fn ext_context_inner(mut context: String, inner_err: &str) -> Error {
    context.push_str(": ");
    context.push_str(inner_err);
    Error(Box::new(context))
}

impl<E: StdError> ExtContext for E {
    fn ext_context(self, context: impl fmt::Display) -> Error {
        Error::from(self).ext_context(context)
    }
}

//
// --- macros ---
//

#[macro_export]
macro_rules! format_err {
    ($($args:tt)+) => ($crate::error::Error(::std::boxed::Box::new(::std::format!($($args)+))))
}

#[cfg(test)]
mod test {
    use super::Context;

    #[test]
    fn error() {
        let result = crate::fs::read_existing_file(std::path::Path::new(
            "aosdifjoasidjfoiasjf",
        ))
        .context("failed to foobar");

        result.expect("failed baz process");
    }
}
