//! `cargo build --unit-graph` JSON types

#![allow(dead_code)]

use std::{
    collections::{btree_map::Entry, BTreeMap},
    ffi::OsStr,
    path::Path,
};

use anyhow::Context;
use nargo_core::nargo;
use serde::Deserialize;

use crate::resolve;

#[derive(Deserialize)]
pub struct UnitGraph<'a> {
    pub version: u32,

    #[serde(borrow)]
    pub units: Vec<Unit<'a>>,

    pub roots: Vec<usize>,
}

#[derive(Deserialize)]
pub struct Unit<'a> {
    pub pkg_id: &'a str,
    #[serde(borrow)]
    pub target: UnitTarget<'a>,
    // pub profile: UnitProfile,
    pub platform: Option<&'a str>,
    pub mode: &'a str,
    #[serde(borrow)]
    pub features: Vec<&'a str>,
    // pub dependencies: Vec<UnitDep>,
}

#[derive(Deserialize)]
pub struct UnitTarget<'a> {
    #[serde(borrow)]
    kind: Vec<&'a str>,
}

// #[derive(Deserialize)]
// pub struct UnitProfile {
//     // TODO
// }
//
// #[derive(Deserialize)]
// pub struct UnitDep {
//     // TODO
// }

#[cfg_attr(test, derive(Debug, PartialEq))]
struct CargoPkgId<'a> {
    name: &'a str,
    version: &'a str,
    source_id: &'a str,
}

// --- impl UnitGraph --- //

impl<'a> UnitGraph<'a> {
    /// Build a map that maps all serialized cargo unit-graph `PackageId`s to
    /// our own "compressed" `PkgId` format.
    pub(crate) fn build_pkg_id_map(
        &'a self,
        workspace_root: &str,
    ) -> BTreeMap<&'a str, String> {
        self.units
            .iter()
            .map(|unit| {
                let cargo_pkg_id = CargoPkgId::parse(unit.pkg_id)
                    .with_context(|| unit.pkg_id.to_owned())
                    .expect("Failed to parse this cargo `PackageId`");
                let cargo_pkg_id_spec = cargo_pkg_id.to_pkg_id_spec();
                let nargo_pkg_id = nargo::PkgId::try_from_cargo_pkg_id(
                    &cargo_pkg_id_spec,
                    workspace_root,
                );
                (unit.pkg_id, nargo_pkg_id.0.to_owned())
            })
            .collect()
    }

    /// Try to build our own nargo feature resolution from the cargo unit-graph
    /// output.
    pub(crate) fn build_resolve_features(
        &'a self,
        pkg_id_map: &'a BTreeMap<&'a str, String>,
        host_target: &'a str,
    ) -> resolve::ResolveFeatures<'a> {
        let mut resolve = BTreeMap::new();

        for unit in &self.units {
            if unit.mode != "build" {
                continue;
            }
            let target_kinds = &unit.target.kind;
            if !(target_kinds.contains(&"lib")
                || target_kinds.contains(&"proc-macro")
                || target_kinds.contains(&"bin"))
            {
                continue;
            }

            let unit_pkg_id = unit.pkg_id;
            let nargo_pkg_id = resolve::PkgId(&pkg_id_map[unit.pkg_id]);
            let feat_for = match unit.platform {
                None => resolve::FeatFor::Build,
                Some(target) if target == host_target =>
                    resolve::FeatFor::Normal,
                Some(target) => panic!(
                    r#"Found unit with unexpected target triple: '{target}', while building
our feature resolution type from the cargo unit-graph:

    --host-target: {host_target}
     cargo pkg_id: {unit_pkg_id}
     nargo pkg_id: {nargo_pkg_id}
"#,
                ),
            };
            let feats = unit
                .features
                .iter()
                .map(|feat| (*feat, ()))
                .collect::<BTreeMap<_, ()>>();

            let by_feat_for: &mut resolve::ByFeatFor<'_> =
                resolve.entry(nargo_pkg_id).or_default();

            let activation = resolve::PkgFeatForActivation {
                feats,
                // deps: BTreeMap::new(),
            };

            // Insert the activation. There might be multiple activations for
            // this package if, for example, there is both a `lib` and a `bin`
            // target for this package. Each activation should be the same,
            // regardless.
            match by_feat_for.entry(feat_for) {
                Entry::Vacant(entry) => {
                    entry.insert(activation);
                }
                Entry::Occupied(prev_entry) => {
                    let prev_activation = prev_entry.get();
                    if prev_entry.get() != &activation {
                        let new_features =
                            activation.feats.keys().copied().join_str(", ");
                        let prev_features = prev_activation
                            .feats
                            .keys()
                            .copied()
                            .join_str(", ");

                        panic!(
                            r#"Bug: multiple activations for this (pkg_id, feat_for) with different
features and/or deps:

   new features: {new_features}
  prev features: {prev_features}

   cargo pkg_id: {unit_pkg_id}
   nargo pkg_id: {nargo_pkg_id}
       feat_for: {feat_for}
  --host-target: {host_target}
"#
                        );
                    }
                }
            }
        }

        resolve
    }
}

trait IteratorExt {
    fn join_str(&mut self, joiner: &str) -> String;
}

impl<'a, I> IteratorExt for I
where
    I: Iterator<Item = &'a str>,
{
    fn join_str(&mut self, joiner: &str) -> String {
        let mut out = match self.next() {
            Some(s) => s.to_owned(),
            None => return String::new(),
        };
        for s in self {
            out.push_str(joiner);
            out.push_str(s);
        }
        out
    }
}

// --- impl CargoPkgId --- //

impl<'a> CargoPkgId<'a> {
    // Parse a `CargoPkgId` from a serialized cargo `PackageId`.
    //
    // ex: "unicode-ident 1.0.12 (registry+https://github.com/rust-lang/crates.io-index)"
    // ex: "nargo-metadata 0.1.0 (path+file:///home/phlip9/dev/nargo/crates/nargo-metadata)"
    fn parse(n_v_s: &'a str) -> Option<Self> {
        let (name, v_s) = n_v_s.split_once(' ')?;
        let (version, s) = v_s.split_once(' ')?;
        let s = s.strip_prefix('(')?;
        let source_id = s.strip_suffix(')')?;
        Some(Self {
            name,
            version,
            source_id,
        })
    }

    // Format this as a cargo `PackageIdSpec` string.
    //
    // ex: "unicode-ident 1.0.12 (registry+https://github.com/rust-lang/crates.io-index)"
    //  -> "registry+https://github.com/rust-lang/crates.io-index#unicode-ident@1.0.12"
    // ex: "nargo-metadata 0.1.0 (path+file:///home/phlip9/dev/nargo/crates/nargo-metadata)"
    //  -> "path+file:///home/phlip9/dev/nargo/crates/nargo-metadata#0.1.0"
    // ex: "dependencies 0.0.0 (path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source)"
    //  -> "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0"
    fn to_pkg_id_spec(&self) -> String {
        let mut out = String::new();

        let mut source_id_includes_name = false;

        // TODO(phlip9): actually parse as a URI
        if let Some(path) = self.source_id.strip_prefix("path+file://") {
            if Path::new(path).file_name().unwrap_or(OsStr::new(""))
                == self.name
            {
                source_id_includes_name = true
            }
        }

        if source_id_includes_name {
            out.push_str(self.source_id);
            out.push('#');
            out.push_str(self.version)
        } else {
            out.push_str(self.source_id);
            out.push('#');
            out.push_str(self.name);
            out.push('@');
            out.push_str(self.version)
        }

        out
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_cargo_pkg_id_parse() {
        let pkg_id = CargoPkgId::parse("unicode-ident 1.0.12 (registry+https://github.com/rust-lang/crates.io-index)");
        assert_eq!(
            pkg_id,
            Some(CargoPkgId {
                name: "unicode-ident",
                version: "1.0.12",
                source_id:
                    "registry+https://github.com/rust-lang/crates.io-index",
            }),
        );

        let pkg_id = CargoPkgId::parse("nargo-metadata 0.1.0 (path+file:///home/phlip9/dev/nargo/crates/nargo-metadata)");
        assert_eq!(
            pkg_id,
            Some(CargoPkgId {
                name: "nargo-metadata",
                version: "0.1.0",
                source_id:
                    "path+file:///home/phlip9/dev/nargo/crates/nargo-metadata",
            }),
        );
    }

    #[test]
    fn test_cargo_pkg_id_to_pkg_id_spec() {
        assert_eq!(
            CargoPkgId::parse("unicode-ident 1.0.12 (registry+https://github.com/rust-lang/crates.io-index)").unwrap()
                .to_pkg_id_spec(),
            "registry+https://github.com/rust-lang/crates.io-index#unicode-ident@1.0.12",
        );
        assert_eq!(
            CargoPkgId::parse("nargo-metadata 0.1.0 (path+file:///home/phlip9/dev/nargo/crates/nargo-metadata)").unwrap()
                .to_pkg_id_spec(),
            "path+file:///home/phlip9/dev/nargo/crates/nargo-metadata#0.1.0",
        );
        assert_eq!(
            CargoPkgId::parse("dependencies 0.0.0 (path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source)").unwrap()
                .to_pkg_id_spec(),
            "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0",
        );
    }
}
