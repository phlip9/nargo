use std::path::Path;
use std::str::FromStr;
use std::{borrow::Cow, collections::BTreeMap};

use nargo_core::{
    error::Context as _,
    nargo::{CrateType, TargetKind},
};
use serde::{Deserialize, Serialize};
use serde_json::ser::{PrettyFormatter, Serializer};
use serde_json::value::RawValue;

use crate::{
    clean,
    input::{self, DepKind, PkgId, Source},
};

type Manifests<'a> = BTreeMap<PkgId<'a>, input::Manifest<'a>>;

#[derive(Serialize, Deserialize)]
pub struct Metadata<'a> {
    #[serde(borrow)]
    pub packages: BTreeMap<PkgId<'a>, Package<'a>>,
    pub workspace_members: Vec<PkgId<'a>>,
    pub workspace_default_members: Vec<PkgId<'a>>,
}

// TODO(phlip9): include extracted crate dir NAR hash so we can more
// efficiently dl after locking.
#[derive(Serialize, Deserialize)]
pub struct Package<'a> {
    pub name: &'a str,

    pub version: semver::Version,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source<'a>>,

    /// Prefetch'ed crates.io crates pin the content hash of their unpacked
    /// store directory here.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hash: Option<SriHash<'a>>,

    /// If this is a workspace crate, then this is the package's relative path
    /// inside the workspace.
    ///
    /// If we're building in the `nix` sandbox, this is a `crane.vendorCargoDeps`
    /// (or similar) nix store path for non-workspace deps. We can't prefetch
    /// inside the sandbox, so we have to passthru this store path.
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<Cow<'a, Path>>,

    pub edition: &'a str,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<&'a str>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_run: Option<&'a str>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<&'a str>,

    #[serde(borrow)]
    #[serde(serialize_with = "compact::features")]
    pub features: Cow<'a, BTreeMap<&'a str, Vec<&'a str>>>,

    #[serde(serialize_with = "compact::deps")]
    pub deps: BTreeMap<PkgId<'a>, PkgDep<'a>>,

    // TODO(phlip9): add `proc_macro: bool` if any target is a proc-macro?
    #[serde(borrow)]
    #[serde(serialize_with = "compact::targets")]
    pub targets: Vec<ManifestTarget<'a>>,
}

#[derive(Serialize, Deserialize)]
pub struct PkgDep<'a> {
    pub name: &'a str,

    #[serde(borrow)]
    #[serde(serialize_with = "compact::dep_kinds")]
    pub kinds: Vec<PkgDepKind<'a>>,
}

#[derive(Serialize, Deserialize)]
pub struct PkgDepKind<'a> {
    #[serde(skip_serializing_if = "DepKind::is_normal")]
    pub kind: DepKind,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<Platform<'a>>,

    #[serde(skip_serializing_if = "bool::is_false")]
    #[serde(default = "bool::default_false")]
    pub optional: bool,

    #[serde(skip_serializing_if = "bool::is_true")]
    #[serde(default = "bool::default_true")]
    pub default: bool,

    #[serde(borrow)]
    #[serde(skip_serializing_if = "slice::is_empty")]
    #[serde(default)]
    pub features: Cow<'a, [&'a str]>,
}

#[derive(Serialize, Deserialize)]
pub struct Platform<'a>(#[serde(borrow)] pub &'a RawValue);

#[derive(Serialize, Deserialize)]
pub struct ManifestTarget<'a> {
    pub name: &'a str,

    pub kind: TargetKind,

    #[serde(borrow)]
    pub crate_types: Cow<'a, [&'a str]>,

    #[serde(borrow)]
    #[serde(skip_serializing_if = "slice::is_empty")]
    #[serde(default)]
    pub required_features: Cow<'a, [&'a str]>,

    pub path: &'a str,

    // TODO(phlip9): is this ever different than the package edition?
    pub edition: &'a str,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct SriHash<'a>(#[serde(borrow)] pub Cow<'a, str>);

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
        current_metadata: Option<&'a Metadata<'a>>,
        assume_vendored: bool,
    ) -> Self {
        let mut deps_arena: Vec<&'a input::ManifestDependency<'a>> =
            Vec::with_capacity(8);

        let curr_pkgs = current_metadata.map(|o| &o.packages);

        let packages: BTreeMap<PkgId<'_>, Package<'_>> = resolve
            .nodes
            .into_iter()
            .map(|node| {
                let id = node.id;
                let curr_pkg =
                    curr_pkgs.and_then(|curr_pkgs| curr_pkgs.get(&id));
                let pkg = Package::from_input(
                    ctx,
                    &mut deps_arena,
                    node,
                    manifests,
                    curr_pkg,
                    assume_vendored,
                );
                (id, pkg)
            })
            .collect();

        Metadata {
            workspace_members,
            workspace_default_members,
            packages,
        }
    }

    /// Like [`serde_json::to_vec_pretty`] but pre-allocates more space and uses
    /// only one space per indent level, to reduce the size of the final file
    /// while staying human-readable.
    pub fn serialize_pretty(&self) -> Vec<u8> {
        let mut buf: Vec<u8> = Vec::with_capacity(32 << 10);
        let formatter = PrettyFormatter::with_indent(b" ");
        let mut serializer = Serializer::with_formatter(&mut buf, formatter);
        self.serialize(&mut serializer)
            .expect("Failed to serialize output json");
        buf
    }

    /// Assert various invariants about the produced `Cargo.metadata.json`.
    pub fn assert_invariants(&self) {
        // `workspace_default_members`
        for pkg_id in &self.workspace_default_members {
            // ...is a strict subset of `workspace_members`
            assert!(self.workspace_members.contains(pkg_id), "{pkg_id}");
        }

        // `workspace_members`
        for pkg_id in &self.workspace_members {
            let pkg = self.packages.get(pkg_id).context(pkg_id).expect(
                "invariant: workspace member not present in generated `packages`",
            );
            assert_eq!(
                pkg.source, None,
                "invariant: workspace member with `source` field"
            );
        }

        // `packages`
        for (pkg_id, pkg) in &self.packages {
            // Check `pkg.hash` and `pkg.path` are appropriate for workspace vs
            // non-workspace
            if pkg.is_workspace() {
                assert_eq!(pkg.hash, None, "{pkg_id}");
                assert_ne!(pkg.path, None, "{pkg_id}");
            } else {
                assert!(pkg.hash.is_some() || pkg.path.is_some(), "{pkg_id}");
            }

            // Check `pkg.deps`
            for dep_pkg_id in pkg.deps.keys() {
                let dep_pkg = self
                    .packages
                    .get(dep_pkg_id)
                    .with_context(|| format!("invariant: missing dep package for package: pkg: {pkg_id}, dep: {dep_pkg_id}"))
                    .unwrap();

                // deps should have a `lib` target
                if !dep_pkg
                    .targets
                    .iter()
                    .any(|target| target.kind == TargetKind::Lib)
                {
                    panic!("invariant: {pkg_id} depends on {dep_pkg_id}, but {dep_pkg_id} doesn't have a `lib` target")
                }
            }
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
        // The same package from the existing Cargo.metadata.json, if it exists.
        curr_pkg: Option<&'a Package<'a>>,
        assume_vendored: bool,
    ) -> Self {
        let id = node.id;
        let manifest = &manifests[&id];

        let name = manifest.name;
        let version = manifest.version.clone();
        let source = manifest.source;

        // Try to get the crate hash from the current Cargo.metadata.json, if
        // this is a crates.io dep.
        //
        // This lets us mostly avoid prefetching unless the actual Cargo.lock
        // deps change.
        let hash = source.filter(Source::is_crates_io).and(curr_pkg).and_then(
            |curr_pkg| {
                // Sanity check
                assert_eq!(name, curr_pkg.name);
                assert_eq!(version, curr_pkg.version);
                assert_eq!(source, curr_pkg.source);

                curr_pkg.hash.clone()
            },
        );

        let is_workspace = source.is_none();
        let path = if is_workspace {
            // We need to record the relative path of workspace crates inside
            // the workspace.
            let path = manifest
                .relative_workspace_path(ctx.workspace_root)
                .unwrap();
            Some(Cow::Borrowed(Path::new(path)))
        } else if !is_workspace && assume_vendored {
            // When building the Cargo.metadata.json inside the `nix build` sandbox,
            // we have to assume the non-workspace crates are already vendored with
            // `crane.vendorCargoDeps` (or similar). In this case, we try to reuse
            // the already vendored crate path.
            let manifest_path = Path::new(manifest.manifest_path);
            let crate_path = manifest_path
                .parent()
                .context("manifest_path is not a file")
                .and_then(|crate_path| {
                    // Canonicalize the path so we get the original /nix/store
                    // path.
                    crate_path
                        .canonicalize()
                        .context("Could not canonicalize crate_path")
                })
                .with_context(|| {
                    format!(
                        "crate: {name}@{version}, manifest_path: '{}'",
                        manifest_path.display()
                    )
                })
                .unwrap();

            Some(Cow::Owned(crate_path))
        } else {
            None
        };

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
            name,
            version,
            hash,
            path,
            source: manifest.source,
            edition: manifest.edition,
            rust_version: manifest.rust_version,
            default_run: manifest.default_run,
            links: manifest.links,
            features: Cow::Borrowed(&manifest.features),
            deps,
            targets,
        }
    }

    /// Returns true if the package is a workspace member.
    #[inline]
    pub(crate) fn is_workspace(&self) -> bool {
        self.source.is_none()
    }

    /// Returns true if the package is a crates.io dependency.
    pub(crate) fn is_crates_io(&self) -> bool {
        self.source.filter(Source::is_crates_io).is_some()
    }

    /// The package name we'll use when prefetching into the nix store.
    /// TODO(phlip9): point to nix prefetcher
    pub(crate) fn prefetch_name(&self) -> String {
        let name = self.name;
        let version = &self.version;
        format!("crate-{name}-{version}")
    }

    /// The crates.io url we download this crate from.
    /// TODO(phlip9): point to nix prefetcher
    pub(crate) fn prefetch_url(&self) -> String {
        let name = self.name;
        let version = &self.version;
        format!("https://static.crates.io/crates/{name}/{version}/download")
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
        let dep_manifest_name = dep_manifest.name;
        let dep_manifest_source_stripped =
            dep_manifest.source.as_ref().map(Source::strip_locked);
        let dep_manifest_path =
            dep_manifest.relative_workspace_path(ctx.workspace_root);
        let dep_manifest_version = &dep_manifest.version;
        let dep_manifest_has_default_feat =
            dep_manifest.features.contains_key("default");

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
                manifest_dep.name == dep_manifest_name
                    && manifest_dep.source.as_ref().map(input::Source::strip_locked)
                        == dep_manifest_source_stripped
                    // Path dependencies only match by path.
                    // Other dependencies match by version.
                    && (if manifest_dep.path.is_some() {
                        manifest_dep.path == dep_manifest_path
                    } else {
                        manifest_dep.req.matches(dep_manifest_version)
                    })
            });
        deps_arena.clear();
        deps_arena.extend(deps_for_pkg_dep);

        assert!(
            !deps_arena.is_empty(),
            r#"
Didn't find _any_ relevant Cargo.toml dependency entries that match:
       package id: '{id}'
    dependency id: '{dep_id}'

dependency: {{
  name: "{dep_manifest_name}",
  source: {dep_manifest_source_stripped:?},
  path: {dep_manifest_path:?},
  version: "{dep_manifest_version}",
}}

'{id}'.dependencies:
{}
"#,
            dump::manifest_deps(&manifest.dependencies),
        );

        // We'll use the pre-snake-case-transformed dep entry rename/dep
        // manifest name (i.e., "iana-time-zone" not "iana_time_zone") to make
        // it easier on the nix side to map `dep:<depName>` features to their
        // corresponding optional dep entries correctly.
        let dep_entry_name = {
            let manifest_dep = deps_arena.first().unwrap();
            manifest_dep.rename.unwrap_or(manifest_dep.name)
        };

        let kinds = dep
            .dep_kinds
            .into_iter()
            .map(|kind| {
                PkgDepKind::from_input(
                    id,
                    dep_id,
                    dep_manifest_has_default_feat,
                    deps_arena,
                    kind,
                    dep_entry_name,
                )
            })
            .collect();

        PkgDep {
            name: dep_entry_name,
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
        dep_manifest_has_default_feat: bool,
        deps_for_pkg_dep: &[&'a input::ManifestDependency<'a>],
        node_dep_kind: input::NodeDepKind<'a>,
        expected_dep_entry_name: &'a str,
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
                r#"There are no matching Cargo.toml dependency entries with this (kind, target):
       package id: '{id}'
    dependency id: '{dep_id}'
    dependency kind: {kind}
    dependency target: {target:?}
"#,
            ))
            .unwrap();

        assert!(
            iter.next().is_none(),
            r#"There are too many matching Cargo.toml dependency entries with this (kind, target):
       package id: '{id}'
    dependency id: '{dep_id}'
    dependency kind: {kind}
    dependency target: {target:?}
"#,
        );

        assert_eq!(
            manifest_dep_entry.rename.unwrap_or(manifest_dep_entry.name),
            expected_dep_entry_name,
            r#"The Cargo.toml manfiest dep entry rename/name appears inconsistent:
       package id: '{id}'
    dependency id: '{dep_id}'
    dependency kind: {kind}
    dependency target: {target:?}
"#
        );

        // If dep_pkg doesn't actually have a "default" feature, then set
        // `default` to `false` unconditionally. This removes several extra
        // checks from the `resolveFeatures` nix fn.
        let default = if !dep_manifest_has_default_feat {
            false
        } else {
            manifest_dep_entry.uses_default_features
        };

        Self {
            kind,
            target: target.map(Platform::from_input),
            optional: manifest_dep_entry.optional,
            default,
            features: Cow::Borrowed(&manifest_dep_entry.features),
        }
    }
}

//
// --- impl ManifestTarget ---
//

impl<'a> ManifestTarget<'a> {
    fn from_input(target: &'a input::ManifestTarget<'a>) -> Self {
        // check crate_types
        for crate_type in &target.crate_types {
            let _ = CrateType::from_str(crate_type).unwrap();
        }

        Self {
            name: target.name,
            kind: target.target_kind(),
            crate_types: Cow::Borrowed(&target.crate_types),
            required_features: Cow::Borrowed(&target.required_features),
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
// and `#[serde(default = "...")]` a little less painful.

mod bool {
    #[inline]
    pub const fn default_false() -> bool {
        false
    }

    #[inline]
    pub const fn default_true() -> bool {
        true
    }

    #[inline]
    pub const fn is_false(x: &bool) -> bool {
        !*x
    }

    #[inline]
    pub const fn is_true(x: &bool) -> bool {
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
    #![allow(clippy::ptr_arg)]

    use std::collections::BTreeMap;

    use serde::ser::{SerializeMap as _, Serializer};
    use serde_json::value::RawValue;

    use super::*;

    pub fn features<'a, S: Serializer>(
        values: &BTreeMap<&'a str, Vec<&'a str>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        let raw_values = values.iter().map(|(&k, v)| {
            let compact_json = serde_json::to_string(v).unwrap();
            (k, RawValue::from_string(compact_json).unwrap())
        });
        serializer.collect_map(raw_values)
    }

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

    pub fn dep_kinds<S: Serializer>(
        values: &Vec<PkgDepKind<'_>>,
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

//
// --- debug output utils ---
//

mod dump {
    use serde::Serialize;

    use crate::{input, output};

    pub fn manifest_deps(
        manifest_deps: &[input::ManifestDependency],
    ) -> String {
        // Only the info relevant for debugging dependency correlation
        #[derive(Serialize)]
        struct Dep<'a> {
            name: &'a str,
            source: Option<input::Source<'a>>,
            req: &'a semver::VersionReq,
            path: Option<&'a str>,
            registry: Option<&'a str>,
            kind: input::DepKind,
            target: Option<output::Platform<'a>>,
        }

        let deps = manifest_deps
            .iter()
            .map(|dep| Dep {
                name: dep.name,
                source: dep.source,
                req: &dep.req,
                path: dep.path,
                registry: dep.registry,
                kind: dep.kind,
                target: dep.target.map(output::Platform::from_input),
            })
            .collect::<Vec<_>>();

        serde_json::to_string_pretty(&deps).unwrap()
    }
}

#[cfg(test)]
mod test {
    use super::*;

    use std::fs;

    #[test]
    fn test_workspace_metadata_serde_roundtrip() {
        let workspace_metadata_json_1 =
            fs::read_to_string("../../Cargo.metadata.json").unwrap();
        let workspace_metadata_1 =
            serde_json::from_str::<Metadata<'_>>(&workspace_metadata_json_1)
                .unwrap();
        let workspace_metadata_json_2 =
            String::from_utf8(workspace_metadata_1.serialize_pretty()).unwrap();

        assert_eq!(workspace_metadata_json_1, workspace_metadata_json_2);
    }
}
