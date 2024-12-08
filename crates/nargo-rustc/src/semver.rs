//! A basic `semver::Version` parser.

use std::fmt;
use std::str::FromStr;

use nargo_core::error::{Context as _, Result};

/// A `semver::Version`. Since `nargo-rustc` just needs the basic components
/// to pass to `build_script_build` binaries, we can avoid most of the `semver`
/// crate machinery.
///
/// NOTE: we don't currently ensure the pre-release and build segments are 100%
/// spec compliant.
#[cfg_attr(test, derive(PartialEq, Eq))]
pub(crate) struct Version<'a> {
    original: &'a str,
    major: &'a str,
    minor: &'a str,
    patch: &'a str,
    pre: Option<&'a str>,
    build: Option<&'a str>,
}

impl<'a> Version<'a> {
    #[inline]
    pub(crate) fn as_str(&self) -> &str {
        self.original
    }
    #[inline]
    pub(crate) fn major(&self) -> &str {
        self.major
    }
    #[inline]
    pub(crate) fn minor(&self) -> &str {
        self.minor
    }
    #[inline]
    pub(crate) fn patch(&self) -> &str {
        self.patch
    }
    #[inline]
    pub(crate) fn pre(&self) -> Option<&str> {
        self.pre
    }
    #[allow(dead_code)]
    #[inline]
    pub(crate) fn build(&self) -> Option<&str> {
        self.build
    }

    pub(crate) fn from_str(s: &'a str) -> Result<Self> {
        Self::parse(s)
            .with_context(|| format!("not a valid semver version: '{s}'"))
    }

    fn parse(input: &'a str) -> Option<Self> {
        let s = input;
        if s.is_empty() {
            return None;
        }

        // <version-core> ::= <major> "." <minor> "." <patch>
        //
        // <semver> ::= <version-core>
        //            | <version-core> "-" <pre>
        //            | <version-core> "+" <build>
        //            | <version-core> "-" <pre> "+" <build>
        let (major, s) = s.split_once('.')?;
        let (minor, s) = s.split_once('.')?;

        let (s, build) = match s.rsplit_once('+') {
            Some((s, build)) if !build.is_empty() => (s, Some(build)),
            _ => (s, None),
        };

        let (s, pre) = match s.split_once('-') {
            Some((s, pre)) if !pre.is_empty() => (s, Some(pre)),
            _ => (s, None),
        };
        let patch = s;

        // <major> ::= <numeric>
        // <minor> ::= <numeric>
        // <patch> ::= <numeric>
        let _ = parse_numeric(major)?;
        let _ = parse_numeric(minor)?;
        let _ = parse_numeric(patch)?;

        // TODO(phlip9): validate pre/build

        Some(Self {
            original: input,
            major,
            minor,
            patch,
            pre,
            build,
        })
    }

    // TODO(phlip9): remove
    pub(crate) fn leak(&self) -> Version<'static> {
        fn box_leak_str(s: &str) -> &'static str {
            Box::leak(Box::<str>::from(s))
        }
        Version {
            original: box_leak_str(self.original),
            major: box_leak_str(self.major),
            minor: box_leak_str(self.minor),
            patch: box_leak_str(self.patch),
            pre: self.pre.map(box_leak_str),
            build: self.build.map(box_leak_str),
        }
    }
}

// <numeric> ::= "0"
//             | <non-zero-digit>
//             | <non-zero-digit> <digits>
fn parse_numeric(s: &str) -> Option<u64> {
    if s.is_empty() {
        return None;
    }
    let n = u64::from_str(s).ok()?;

    // No leading zero
    if n != 0 && s.starts_with('0') {
        None
    } else {
        Some(n)
    }
}

impl<'a> fmt::Display for Version<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
impl<'a> fmt::Debug for Version<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

#[cfg(test)]
mod test {
    use nargo_core::error::Error;

    use super::*;

    fn display(v: &Version) -> String {
        let mut out = String::new();
        out.push_str(v.major);
        out.push('.');
        out.push_str(v.minor);
        out.push('.');
        out.push_str(v.patch);
        if let Some(pre) = v.pre {
            out.push('-');
            out.push_str(pre);
        }
        if let Some(build) = v.build {
            out.push('+');
            out.push_str(build);
        }
        out
    }

    fn version(s: &str) -> Version {
        let version =
            Version::from_str(s).expect("this semver::Version should parse");
        assert_eq!(version.original, s);
        assert_eq!(version.original, display(&version));
        version
    }

    fn version_err(s: &str) -> Error {
        Version::from_str(s).expect_err("this semver::Version should not parse")
    }

    macro_rules! version_new {
        ($major:literal, $minor:literal, $patch:literal, $pre:literal, $build:literal) => {
            $crate::semver::Version {
                original: concat!(
                    $major, ".", $minor, ".", $patch, "-", $pre, "+", $build
                ),
                major: $major,
                minor: $minor,
                patch: $patch,
                pre: Some($pre),
                build: Some($build),
            }
        };
        ($major:literal, $minor:literal, $patch:literal, $pre:literal, _) => {
            $crate::semver::Version {
                original: concat!($major, ".", $minor, ".", $patch, "-", $pre),
                major: $major,
                minor: $minor,
                patch: $patch,
                pre: Some($pre),
                build: None,
            }
        };
        ($major:literal, $minor:literal, $patch:literal, _, $build:literal) => {
            $crate::semver::Version {
                original: concat!(
                    $major, ".", $minor, ".", $patch, "+", $build
                ),
                major: $major,
                minor: $minor,
                patch: $patch,
                pre: None,
                build: Some($build),
            }
        };
        ($major:literal, $minor:literal, $patch:literal, _, _) => {
            $crate::semver::Version {
                original: concat!($major, ".", $minor, ".", $patch),
                major: $major,
                minor: $minor,
                patch: $patch,
                pre: None,
                build: None,
            }
        };
    }

    #[test]
    fn parse() {
        version_err("");
        version_err("  ");
        version_err("1");
        version_err("1.2");
        version_err("1.2.");
        version_err("1..4");
        version_err("1.2.3-");
        version_err("a.b.c");
        version_err("1.2.3 abc");
        // version_err("1.2.3-01"); // TODO
        version_err("1.2.3++");
        version_err("07");
        version_err("07.01.1");
        version_err("7.01.1");
        version_err("7.1.01");

        assert_eq!(version("1.2.3"), version_new!("1", "2", "3", _, _));
        assert_eq!(
            version("1.2.3-alpha1"),
            version_new!("1", "2", "3", "alpha1", _)
        );
        assert_eq!(
            version("1.2.3+build5"),
            version_new!("1", "2", "3", _, "build5")
        );
        assert_eq!(
            version("1.2.3-alpha1+build5"),
            version_new!("1", "2", "3", "alpha1", "build5")
        );
        assert_eq!(
            version("1.2.3-0a.alpha1.9+05build.7.3aedf"),
            version_new!("1", "2", "3", "0a.alpha1.9", "05build.7.3aedf")
        );
        assert_eq!(
            version("0.4.0-beta.1+0851523"),
            version_new!("0", "4", "0", "beta.1", "0851523")
        );
        assert_eq!(
            version("1.1.0-beta-10"),
            version_new!("1", "1", "0", "beta-10", _)
        );
    }
}
