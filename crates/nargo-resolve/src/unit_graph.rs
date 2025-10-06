//! `cargo build --unit-graph` JSON types

use std::collections::{btree_map::Entry, BTreeMap};

use nargo_core::nargo;
use serde::Deserialize;

use crate::resolve;

#[derive(Deserialize)]
pub struct UnitGraph<'a> {
    pub version: u32,

    #[serde(borrow)]
    pub units: Vec<Unit<'a>>,
    //
    // pub roots: Vec<usize>,
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
                let nargo_pkg_id = nargo::PkgId::try_from_cargo_pkg_id_spec(
                    unit.pkg_id,
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

            // We only want `TargetKind::Lib(_) | TargetKind::Bin` targets here.
            // We'll check for the negation here b/c it's easier.
            // see `impl Serialize for TargetKind` in cargo src.
            let target_kinds = &unit.target.kind;
            if let ["bench" | "custom-build" | "example" | "test"] =
                target_kinds.as_slice()
            {
                continue;
            }

            let unit_pkg_id = unit.pkg_id;
            let nargo_pkg_id = resolve::PkgId(&pkg_id_map[unit.pkg_id]);
            let feat_for = match unit.platform {
                None => resolve::FeatFor::Build,
                Some(target) if target == host_target => {
                    resolve::FeatFor::Normal
                }
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
