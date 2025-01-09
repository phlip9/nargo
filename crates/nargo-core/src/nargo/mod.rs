//! nargo types

use std::{fmt, str::FromStr};

use crate::{
    error::{Context as _, Error},
    format_err,
};

#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

const CRATES_IO_REGISTRY: &str =
    "registry+https://github.com/rust-lang/crates.io-index";

/// A nargo-specific compact package ID. Conveniently, it is always a strict
/// substring of a cargo `PackageIdSpec`.
///
/// Why this is not just a cargo `PackageIdSpec`:
/// 1. the `Cargo.metadata.json` is more compact and easier to read and audit
/// 2. it's easier to build specific workspace and crates.io packages from the
///    nix nargo build graph.
#[derive(Copy, Clone, Ord, PartialOrd, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(Deserialize, Serialize))]
#[cfg_attr(test, derive(Debug))]
pub struct PkgId<'a>(pub &'a str);

/// A cargo package target kind.
///
/// Like `cargo::core::manifest::TargetKind` but we keep the rustc `crate-type`
/// in a separate field.
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum TargetKind {
    Lib,
    Bin,
    Test,
    Bench,
    ExampleBin,
    ExampleLib,
    CustomBuild,
}

/// Types of the output artifact that the compiler emits.
///
/// Like `cargo::core::compiler::CrateType` but without the `Other` field.
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum CrateType {
    Bin,
    Lib,
    Rlib,
    Dylib,
    Cdylib,
    Staticlib,
    ProcMacro,
}

//
// --- impl PkgId ---
//

impl<'a> PkgId<'a> {
    pub fn try_from_cargo_pkg_id_spec<'b>(
        id: &'a str,
        workspace_root: &'b str,
    ) -> Self {
        Self::try_from_cargo_pkg_id_spec_inner(id, workspace_root)
            .context(id)
            .expect("Failed to convert serialized cargo PackageIdSpec")
    }

    fn try_from_cargo_pkg_id_spec_inner<'b>(
        id: &'a str,
        workspace_root: &'b str,
    ) -> Option<Self> {
        // Workspace packages should be addressed by their package name.
        //
        // ex: "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0"
        //  -> "age"
        // ex: "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/crates/age#0.10.0"
        //  -> "age"
        // ex: "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0"
        // -> "dependencies"
        if let Some(rest) = id.strip_prefix("path+file://") {
            // TODO(phlip9): support path dep on non-workspace crate?
            let rest = rest.strip_prefix(workspace_root)?;

            let (path, fragment) = rest.rsplit_once('#')?;

            // If the last path segment DOESN'T match the package name, cargo
            // places it in the URL fragment like "<name>@<version>".
            if let Some((name, _version)) = fragment.split_once('@') {
                return Some(Self(name));
            }

            // Else grab the name from last path segment
            let (_, name) = path.rsplit_once('/').unwrap_or(("", path));
            return Some(Self(name));
        }

        // ex: "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3"
        // -> "aes-gcm@0.10.3"
        if let Some(rest) = id.strip_prefix(CRATES_IO_REGISTRY) {
            return Some(Self(rest.trim_start_matches('#')));
        }

        // ex: (unchanged) "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7"
        Some(Self(id))
    }
}

//
// --- impl TargetKind ---
//

impl TargetKind {
    /// Parse the `TargetKind` from cargo's serialized target `kind` and
    /// `crate_types`.
    pub fn try_from_cargo_kind<'a>(
        mut kinds: impl Iterator<Item = &'a str>,
        mut crate_types: impl Iterator<Item = &'a str>,
    ) -> Self {
        match kinds.next().expect("empty target `kind`") {
            "bench" => return Self::Bench,
            "bin" => return Self::Bin,
            "custom-build" => return Self::CustomBuild,
            "example" => (),
            "test" => return Self::Test,
            _ => return Self::Lib,
        }

        // determine example kind from `crate_types`
        match crate_types.next().expect("empty target `crate_type`") {
            "bin" => Self::ExampleBin,
            _ => Self::ExampleLib,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Lib => "lib",
            Self::Bin => "bin",
            Self::Test => "test",
            Self::Bench => "bench",
            Self::ExampleBin => "example-bin",
            Self::ExampleLib => "example-lib",
            Self::CustomBuild => "custom-build",
        }
    }
}

impl FromStr for TargetKind {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "lib" => Ok(Self::Lib),
            "bin" => Ok(Self::Bin),
            "test" => Ok(Self::Test),
            "bench" => Ok(Self::Bench),
            "example-bin" => Ok(Self::ExampleBin),
            "example-lib" => Ok(Self::ExampleLib),
            "custom-build" => Ok(Self::CustomBuild),
            _ => Err(format_err!("invalid `kind`: '{s}'")),
        }
    }
}

impl fmt::Display for TargetKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
impl fmt::Debug for TargetKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

#[cfg(feature = "serde")]
impl serde::Serialize for TargetKind {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}
#[cfg(feature = "serde")]
impl<'de> serde::Deserialize<'de> for TargetKind {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Self, D::Error> {
        let s = <&str>::deserialize(deserializer)?;
        TargetKind::from_str(s).map_err(serde::de::Error::custom)
    }
}

//
// --- impl CrateType ---
//

impl CrateType {
    pub fn can_lto(&self) -> bool {
        match self {
            CrateType::Bin | CrateType::Staticlib | CrateType::Cdylib => true,
            CrateType::Lib
            | CrateType::Rlib
            | CrateType::Dylib
            | CrateType::ProcMacro => false,
        }
    }

    pub fn is_linkable(&self) -> bool {
        match self {
            CrateType::Lib
            | CrateType::Rlib
            | CrateType::Dylib
            | CrateType::ProcMacro => true,
            CrateType::Bin | CrateType::Cdylib | CrateType::Staticlib => false,
        }
    }

    pub fn is_dynamic(&self) -> bool {
        match self {
            CrateType::Dylib | CrateType::Cdylib | CrateType::ProcMacro => true,
            CrateType::Lib
            | CrateType::Rlib
            | CrateType::Bin
            | CrateType::Staticlib => false,
        }
    }

    pub fn requires_upstream_objects(&self) -> bool {
        !matches!(self, CrateType::Lib | CrateType::Rlib)
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Bin => "bin",
            Self::Lib => "lib",
            Self::Rlib => "rlib",
            Self::Dylib => "dylib",
            Self::Cdylib => "cdylib",
            Self::Staticlib => "staticlib",
            Self::ProcMacro => "proc-macro",
        }
    }
}

impl FromStr for CrateType {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "bin" => Self::Bin,
            "lib" => Self::Lib,
            "rlib" => Self::Rlib,
            "dylib" => Self::Dylib,
            "cdylib" => Self::Cdylib,
            "staticlib" => Self::Staticlib,
            "proc-macro" => Self::ProcMacro,
            _ => return Err(format_err!("invalid crate-type: '{s}'")),
        })
    }
}

impl fmt::Display for CrateType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
impl fmt::Debug for CrateType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

#[cfg(feature = "serde")]
impl serde::Serialize for CrateType {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}
#[cfg(feature = "serde")]
impl<'de> serde::Deserialize<'de> for CrateType {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Self, D::Error> {
        let s = <&str>::deserialize(deserializer)?;
        CrateType::from_str(s).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn pkg_id_try_from_cargo_pkg_id_spec() {
        #[track_caller]
        fn ok(expected: &str, id: &str) {
            let workspace_root =
                "/nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source";
            let id_clean =
                PkgId::try_from_cargo_pkg_id_spec_inner(id, workspace_root);
            assert_eq!(id_clean, Some(PkgId(expected)));
        }

        ok("age", "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0");
        ok("age", "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/crates/age#0.10.0");
        ok("dependencies", "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source#dependencies@0.0.0");
        ok("dependencies", "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/other-path#dependencies@0.0.0");
        ok("aes-gcm@0.10.3", "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3");
        let id =  "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7";
        ok(id, id);
    }

    #[test]
    fn target_kind_from_cargo() {
        use TargetKind::*;
        let cases = [
            ("lib", "lib", Lib),
            ("cdylib", "cdylib", Lib),
            ("lib,cdylib,staticlib", "lib,cdylib,staticlib", Lib),
            ("bin", "bin", Bin),
            ("test", "bin", Test),
            ("bench", "bin", Bench),
            ("example", "bin", ExampleBin),
            ("example", "lib", ExampleLib),
            ("example", "cdylib", ExampleLib),
            ("example", "lib,cdylib,staticlib", ExampleLib),
            ("custom-build", "bin", CustomBuild),
        ];
        for (kinds_str, crate_types_str, expected) in cases {
            let kinds = kinds_str.split(',');
            let crate_types = crate_types_str.split(',');
            let actual = TargetKind::try_from_cargo_kind(kinds, crate_types);
            assert_eq!(
                actual, expected,
                "kind: {kinds_str}, crate_type: {crate_types_str}"
            );
        }
    }

    const TARGET_KINDS: [TargetKind; 7] = {
        use TargetKind::*;
        [Lib, Bin, Test, Bench, ExampleBin, ExampleLib, CustomBuild]
    };

    #[test]
    fn target_kind_roundtrip() {
        let kinds = TARGET_KINDS.to_vec();
        let kinds_ser = kinds
            .iter()
            .map(|k| k.as_str().to_owned())
            .collect::<Vec<_>>();
        let kinds_ser_de = kinds_ser
            .iter()
            .map(|k| TargetKind::from_str(k).unwrap())
            .collect::<Vec<_>>();
        let kinds_ser_de_ser = kinds_ser_de
            .iter()
            .map(|k| k.to_string())
            .collect::<Vec<_>>();
        assert_eq!(kinds, kinds_ser_de);
        assert_eq!(kinds_ser, kinds_ser_de_ser);
    }
}
