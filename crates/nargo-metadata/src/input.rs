//! Parse input from `cargo metadata` json.

#![allow(dead_code)]

use std::collections::BTreeMap;

use serde::Deserialize;
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

    pub source: Option<&'a str>,

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

    pub source: Option<&'a str>,

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

pub enum DepKind {
    Normal,
    Dev,
    Build,
}

#[derive(Deserialize)]
pub struct PkgId<'a>(pub &'a str);

#[derive(Deserialize)]
pub struct Platform<'a>(#[serde(borrow)] pub &'a RawValue);

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
