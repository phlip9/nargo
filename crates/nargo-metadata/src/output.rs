use std::collections::BTreeMap;

use anyhow::Context as _;
use serde::Serialize;
use serde_json::value::RawValue;

use crate::{
    clean,
    input::{self, DepKind, PkgId, Source},
};

type Manifests<'a> = BTreeMap<PkgId<'a>, input::Manifest<'a>>;

#[derive(Serialize)]
pub struct Metadata<'a> {
    pub packages: BTreeMap<PkgId<'a>, Package<'a>>,
    pub workspace_members: Vec<PkgId<'a>>,
    pub workspace_default_members: Vec<PkgId<'a>>,
}

// TODO(phlip9): include extracted crate dir NAR hash so we can more
// efficiently dl after locking.
#[derive(Serialize)]
pub struct Package<'a> {
    pub name: &'a str,
    pub version: semver::Version,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source<'a>>,
    pub edition: &'a str,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<&'a str>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_run: Option<&'a str>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<&'a str>,

    #[serde(serialize_with = "compact::deps")]
    pub deps: BTreeMap<PkgId<'a>, PkgDep<'a>>,

    #[serde(serialize_with = "compact::targets")]
    pub targets: Vec<ManifestTarget<'a>>,
}

#[derive(Serialize)]
pub struct PkgDep<'a> {
    pub name: &'a str,

    #[serde(serialize_with = "compact::dep_kinds")]
    pub kinds: Vec<PkgDepKind<'a>>,
}

#[derive(Serialize)]
pub struct PkgDepKind<'a> {
    #[serde(skip_serializing_if = "DepKind::is_normal")]
    pub kind: DepKind,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<Platform<'a>>,

    #[serde(skip_serializing_if = "bool::is_false")]
    pub optional: bool,

    #[serde(skip_serializing_if = "bool::is_true")]
    pub default: bool,

    #[serde(skip_serializing_if = "slice::is_empty")]
    pub features: &'a [&'a str],
}

#[derive(Serialize)]
pub struct Platform<'a>(pub &'a RawValue);

#[derive(Serialize)]
pub struct ManifestTarget<'a> {
    pub name: &'a str,

    pub kind: &'a [&'a str],

    pub crate_types: &'a [&'a str],

    #[serde(skip_serializing_if = "slice::is_empty")]
    pub required_features: &'a [&'a str],

    pub path: &'a str,

    // TODO(phlip9): is this ever different than the package edition?
    pub edition: &'a str,
}

//
// --- impl Metadata ---
//

impl<'a> Metadata<'a> {
    pub fn from_input<'ctx: 'a>(
        ctx: clean::Context<'ctx>,
        manifests: &'a Manifests<'a>,
        workspace_members: Vec<PkgId<'a>>,
        workspace_default_members: Vec<PkgId<'a>>,
        resolve: input::Resolve<'a>,
    ) -> Self {
        let mut deps_arena: Vec<&'a input::ManifestDependency<'a>> =
            Vec::with_capacity(8);

        let packages: BTreeMap<PkgId<'_>, Package<'_>> = resolve
            .nodes
            .into_iter()
            .map(|node| {
                let id = node.id;
                let pkg =
                    Package::from_input(ctx, &mut deps_arena, node, manifests);
                (id, pkg)
            })
            .collect();

        Metadata {
            workspace_members,
            workspace_default_members,
            packages,
        }
    }
}

//
// --- impl Package ---
//

impl<'a> Package<'a> {
    fn from_input(
        ctx: clean::Context<'a>,
        deps_arena: &mut Vec<&'a input::ManifestDependency<'a>>,
        node: input::Node<'a>,
        manifests: &'a Manifests<'a>,
    ) -> Self {
        let id = node.id;
        let manifest = &manifests[&id];

        let targets: Vec<ManifestTarget<'_>> = manifest
            .targets
            .iter()
            .map(ManifestTarget::from_input)
            .collect();

        let deps: BTreeMap<PkgId, PkgDep> = node
            .deps
            .into_iter()
            .map(|dep| {
                let dep_id = dep.pkg;
                let pkg_dep =
                    PkgDep::from_input(ctx, deps_arena, id, dep, manifests);
                (dep_id, pkg_dep)
            })
            .collect();

        Self {
            name: manifest.name,
            version: manifest.version.clone(),
            edition: manifest.edition,
            rust_version: manifest.rust_version,
            source: manifest.source,
            default_run: manifest.default_run,
            links: manifest.links,
            deps,
            targets,
        }
    }
}

//
// --- impl PkgDep ---
//

impl<'a> PkgDep<'a> {
    fn from_input(
        ctx: clean::Context<'a>,
        deps_arena: &mut Vec<&'a input::ManifestDependency<'a>>,
        id: PkgId<'a>,
        dep: input::NodeDep<'a>,
        manifests: &'a Manifests<'a>,
    ) -> Self {
        let dep_id = dep.pkg;
        let dep_manifest = &manifests[&dep_id];
        let dep_manifest_source_stripped =
            dep_manifest.source.as_ref().map(Source::strip_locked);
        let dep_manifest_path =
            dep_manifest.relative_workspace_path(ctx.workspace_src);

        let manifest = &manifests[&id];

        // `cargo metadata`'s `resolve` output doesn't give us enough info to do
        // our own feature resolution, so we have to grab this info from the
        // original Cargo.toml manifest (`manifest`).
        //
        // Here, we're doing one linear search to find all the instances of this
        // dep (given by `dep_id`) in the dependent package's `dependencies`
        // list. We'll then search through this smaller list for each specific
        // (kind, target)-dep entry below.
        let deps_for_pkg_dep =
            manifest.dependencies.iter().filter(|&manifest_dep| {
                manifest_dep.name == dep_manifest.name
                    && manifest_dep.source == dep_manifest_source_stripped
                    && manifest_dep.path == dep_manifest_path
                    && manifest_dep.req.matches(&dep_manifest.version)
            });
        deps_arena.clear();
        deps_arena.extend(deps_for_pkg_dep);

        assert!(
            !deps_arena.is_empty(),
            "Didn't find _any_ relevant Cargo.toml dependency entries that match:\n\
                    package id: '{id}'\n\
                 dependency id: '{dep_id}'\n\
            "
        );

        let kinds = dep
            .dep_kinds
            .into_iter()
            .map(|kind| PkgDepKind::from_input(id, dep_id, deps_arena, kind))
            .collect();

        PkgDep {
            name: dep.name,
            kinds,
        }
    }
}

//
// --- impl PkgDepKind ---
//

impl<'a> PkgDepKind<'a> {
    fn from_input(
        id: PkgId<'a>,
        dep_id: PkgId<'a>,
        deps_for_pkg_dep: &[&'a input::ManifestDependency<'a>],
        node_dep_kind: input::NodeDepKind<'a>,
    ) -> Self {
        let kind = node_dep_kind.kind;
        let target = node_dep_kind.target;

        let mut iter = deps_for_pkg_dep
            .iter()
            .filter(|dep| dep.kind == kind && dep.target == target);

        // There should be exactly one matching entry
        let manifest_dep_entry = iter
            .next()
            .with_context(|| format!(
                "There are no matching Cargo.toml dependency entries with this (kind, target):\n\
                       package id: '{id}'\n\
                    dependency id: '{dep_id}'\n\
                    dependency kind: {kind}\n\
                    dependency target: {target:?}\n\
                ",
            ))
            .unwrap();

        assert!(
            iter.next().is_none(),
            "There are too many matching Cargo.toml dependency entries with this (kind, target):\n\
                   package id: '{id}'\n\
                dependency id: '{dep_id}'\n\
                dependency kind: {kind}\n\
                dependency target: {target:?}\n\
            ",
        );

        Self {
            kind,
            target: target.map(Platform::from_input),
            optional: manifest_dep_entry.optional,
            default: manifest_dep_entry.uses_default_features,
            features: &manifest_dep_entry.features,
        }
    }
}

//
// --- impl ManifestTarget ---
//

impl<'a> ManifestTarget<'a> {
    fn from_input(target: &'a input::ManifestTarget<'a>) -> Self {
        Self {
            name: target.name,
            kind: &target.kind,
            crate_types: &target.crate_types,
            required_features: &target.required_features,
            path: target.src_path,
            edition: target.edition,
        }
    }
}

//
// --- impl Platform ---
//

impl<'a> Platform<'a> {
    fn from_input(platform: input::Platform<'a>) -> Self {
        // TODO(phlip9): impl
        Self(platform.0)
    }
}

//
// --- serde utils ---
//

// These trivial helper functions make `#[serde(skip_serializing_if = "...")]`
// a little less painful.

mod bool {
    #[inline]
    pub fn is_false(x: &bool) -> bool {
        !*x
    }

    #[inline]
    pub fn is_true(x: &bool) -> bool {
        *x
    }
}

mod slice {
    #[inline]
    pub fn is_empty<T>(x: &[T]) -> bool {
        x.is_empty()
    }
}

/// `#[serde(serialize_with = "...")]` helpers that make the output more
/// compact.
mod compact {
    use std::collections::BTreeMap;

    use serde::ser::{SerializeMap as _, Serializer};
    use serde_json::value::RawValue;

    use super::*;

    pub fn deps<'a, S: Serializer>(
        values: &BTreeMap<PkgId<'a>, PkgDep<'a>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        let mut map_serializer =
            serializer.serialize_map(Some(values.len()))?;

        for (id, dep) in values {
            let one_line_string = serde_json::to_string(dep).unwrap();
            // If the compact output is short enough, serialize that
            if dep.kinds.len() <= 1 || one_line_string.len() <= 140 {
                map_serializer.serialize_entry(
                    id,
                    &RawValue::from_string(one_line_string).unwrap(),
                )?;
            } else {
                map_serializer.serialize_entry(id, dep)?
            }
        }

        map_serializer.end()
    }

    pub fn dep_kinds<'a, S: Serializer>(
        values: &Vec<PkgDepKind<'a>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        let raw_values = values.iter().map(|value| {
            let compact_json = serde_json::to_string(value).unwrap();
            RawValue::from_string(compact_json).unwrap()
        });
        serializer.collect_seq(raw_values)
    }

    pub fn targets<S: Serializer>(
        values: &Vec<ManifestTarget>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        let raw_values = values.iter().map(|value| {
            let compact_json = serde_json::to_string(value).unwrap();
            RawValue::from_string(compact_json).unwrap()
        });
        serializer.collect_seq(raw_values)
    }
}
