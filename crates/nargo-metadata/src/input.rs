//! Parse input from `cargo metadata` json.

#![allow(dead_code)]

use std::{cmp, collections::BTreeMap, fmt};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

#[derive(Deserialize)]
pub struct Metadata<'a> {
    #[serde(borrow)]
    pub packages: Vec<Manifest<'a>>,

    #[serde(borrow)]
    pub workspace_members: Vec<PkgId<'a>>,

    #[serde(borrow)]
    pub workspace_default_members: Vec<PkgId<'a>>,

    #[serde(borrow)]
    pub resolve: Resolve<'a>,
}

#[derive(Deserialize)]
pub struct Manifest<'a> {
    pub name: &'a str,

    pub version: semver::Version,

    #[serde(borrow)]
    pub id: PkgId<'a>,

    #[serde(borrow)]
    pub source: Option<Source<'a>>,

    #[serde(borrow)]
    pub dependencies: Vec<ManifestDependency<'a>>,

    #[serde(borrow)]
    pub targets: Vec<ManifestTarget<'a>>,

    #[serde(borrow)]
    pub features: BTreeMap<&'a str, Vec<&'a str>>,

    pub manifest_path: &'a str,

    pub edition: &'a str,

    pub links: Option<&'a str>,

    pub default_run: Option<&'a str>,

    pub rust_version: Option<&'a str>,
}

#[derive(Deserialize)]
pub struct ManifestDependency<'a> {
    pub name: &'a str,

    #[serde(borrow)]
    pub source: Option<Source<'a>>,

    pub req: semver::VersionReq,

    pub kind: DepKind,

    pub optional: bool,

    pub uses_default_features: bool,

    #[serde(borrow)]
    pub features: Vec<&'a str>,

    #[serde(borrow)]
    pub target: Option<Platform<'a>>,

    pub rename: Option<&'a str>,

    pub registry: Option<&'a str>,

    #[serde(borrow)]
    pub path: Option<&'a str>,
}

#[derive(Deserialize)]
pub struct ManifestTarget<'a> {
    pub name: &'a str,

    #[serde(borrow)]
    pub kind: Vec<&'a str>,

    #[serde(borrow)]
    pub crate_types: Vec<&'a str>,

    #[serde(default)]
    #[serde(borrow)]
    pub required_features: Vec<&'a str>,

    pub src_path: &'a str,

    pub edition: &'a str,
}

#[derive(Deserialize)]
pub struct Resolve<'a> {
    #[serde(borrow)]
    pub nodes: Vec<Node<'a>>,
}

#[derive(Deserialize)]
pub struct Node<'a> {
    #[serde(borrow)]
    pub id: PkgId<'a>,

    #[serde(borrow)]
    pub deps: Vec<NodeDep<'a>>,
}

#[derive(Deserialize)]
pub struct NodeDep<'a> {
    pub name: &'a str,

    #[serde(borrow)]
    pub pkg: PkgId<'a>,

    #[serde(borrow)]
    pub dep_kinds: Vec<NodeDepKind<'a>>,
}

#[derive(Deserialize)]
pub struct NodeDepKind<'a> {
    pub kind: DepKind,

    #[serde(borrow)]
    pub target: Option<Platform<'a>>,
}

#[derive(Eq, PartialEq, Ord, PartialOrd)]
pub enum DepKind {
    Normal,
    Dev,
    Build,
}

#[derive(Copy, Clone, Ord, PartialOrd, Eq, PartialEq, Deserialize, Serialize)]
pub struct PkgId<'a>(pub &'a str);

#[derive(Eq, PartialEq, Deserialize)]
pub struct Source<'a>(pub &'a str);

#[derive(Deserialize)]
pub struct Platform<'a>(#[serde(borrow)] pub &'a RawValue);

//
// --- impl Manifest ---
//

impl<'a> Manifest<'a> {
    pub fn is_workspace_pkg(&self) -> bool {
        self.source.is_none()
    }

    /// The directory path that contains the `Cargo.toml` manifest.
    pub fn manifest_dir(&self) -> &'a str {
        self.manifest_path
            .strip_suffix("Cargo.toml")
            .with_context(|| {
                let id = self.id;
                let mp = self.manifest_path;
                format!("Failed to get dir from this manifest_path: '{mp}'. Manifest: '{id}'")
            })
            .unwrap()
    }
}

//
// --- impl DepKind ---
//

impl<'de> serde::Deserialize<'de> for DepKind {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        match Option::<&'de str>::deserialize(deserializer)? {
            None => Ok(Self::Normal),
            Some("dev") => Ok(Self::Dev),
            Some("build") => Ok(Self::Build),
            Some(var) =>
                Err(serde::de::Error::unknown_variant(var, &["dev", "build"])),
        }
    }
}

//
// --- impl PkgId ---
//

impl<'a> fmt::Display for PkgId<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

//
// --- impl Platform ---
//

impl<'a> cmp::Eq for Platform<'a> {}

impl<'a> cmp::PartialEq for Platform<'a> {
    fn eq(&self, other: &Self) -> bool {
        self.0.get() == other.0.get()
    }
}

impl<'a> cmp::Ord for Platform<'a> {
    fn cmp(&self, other: &Self) -> cmp::Ordering {
        self.0.get().cmp(other.0.get())
    }
}

impl<'a> cmp::PartialOrd for Platform<'a> {
    fn partial_cmp(&self, other: &Self) -> Option<cmp::Ordering> {
        Some(self.cmp(other))
    }
}
