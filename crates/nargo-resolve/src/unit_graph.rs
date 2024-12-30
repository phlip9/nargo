//! `cargo build --unit-graph` JSON types

use std::{
    borrow::Cow,
    collections::{btree_map::Entry, BTreeMap},
    fmt::{self, Write},
};

use nargo_core::{error::Context, nargo};
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

        let mut source_id = Cow::Borrowed(self.source_id);
        let mut source_id_includes_name = false;

        if let Some(mut url) = Url::parse(&source_id) {
            // if the last path segment is the package name, then cargo doesn't
            // include the package name in the suffix
            let last_segment =
                url.authority_path.rsplit_once('/').map(|xy| xy.1);
            source_id_includes_name = last_segment == Some(self.name);

            // cargo also strips the url fragment (?)
            if url.fragment.is_some() {
                url.fragment = None;
                source_id = Cow::Owned(url.to_string());
            }
        }

        if source_id_includes_name {
            out.push_str(&source_id);
            out.push('#');
            out.push_str(self.version)
        } else {
            out.push_str(&source_id);
            out.push('#');
            out.push_str(self.name);
            out.push('@');
            out.push_str(self.version)
        }

        out
    }
}

/// A (technically non-compliant) parsed URL.
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct Url<'a> {
    scheme: &'a str,
    authority_path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

impl<'a> Url<'a> {
    fn parse(s: &'a str) -> Option<Self> {
        let (scheme, rest) = s.split_once("://")?;
        let (rest, fragment) = match rest.rsplit_once('#') {
            Some((rest, fragment)) => (rest, Some(fragment)),
            None => (rest, None),
        };
        let (authority_path, query) = match rest.rsplit_once('?') {
            Some((rest, query)) => (rest, Some(query)),
            None => (rest, None),
        };
        Some(Url {
            scheme,
            authority_path,
            query,
            fragment,
        })
    }
}

impl fmt::Display for Url<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.scheme)?;
        f.write_str("://")?;

        f.write_str(self.authority_path)?;

        if let Some(query) = self.query {
            f.write_char('?')?;

            // need to url-encode query string values
            // TODO(phlip9): this is only true for cargo 1.83+ (?)
            let mut is_first = true;
            for query_kv in query.split('&') {
                if is_first {
                    is_first = false;
                } else {
                    f.write_char('&')?;
                }

                let (key, value) = query_kv.split_once('=').with_context(|| format!("invalid url query string, missing '=' in kv pair: '{query}'")).unwrap();

                f.write_str(key)?;
                f.write_char('=')?;

                let value_encoded = url_encode::byte_serialize(value);
                f.write_str(&value_encoded)?;
            }
        }

        if let Some(fragment) = self.fragment {
            f.write_char('#')?;
            f.write_str(fragment)?;
        }
        Ok(())
    }
}

mod url_encode {
    use std::{borrow::Cow, str};

    // https://url.spec.whatwg.org/#concept-urlencoded-byte-serializer
    pub fn byte_serialize(s: &str) -> Cow<'_, str> {
        // check if this string contains any bytes that need to be encoded. o/w
        // just return original.
        let mut bs = s.as_bytes();
        if bs.iter().all(|&b| byte_serialized_unchanged(b)) {
            return Cow::Borrowed(s);
        }

        // iterate over the clean segments, separated by a byte that needs to be
        // encoded. then url-encode that byte.
        let mut out = String::with_capacity(s.len());
        while let Some(idx) =
            bs.iter().position(|&b| !byte_serialized_unchanged(b))
        {
            let (clean_prefix, suffix) = bs.split_at(idx);
            let (byte, suffix_to_parse) = suffix.split_first().unwrap();
            let byte = *byte;

            out.push_str(str::from_utf8(clean_prefix).unwrap());

            // encode byte
            if byte == b' ' {
                out.push('+');
            } else {
                out.push('%');
                out.push(hex_encode_nibble(byte >> 4) as char);
                out.push(hex_encode_nibble(byte & 0x0f) as char);
            }

            bs = suffix_to_parse;
        }

        // append the final clean segment
        out.push_str(str::from_utf8(bs).unwrap());

        Cow::Owned(out)
    }

    // Bytes that don't need to be url-encoded.
    fn byte_serialized_unchanged(byte: u8) -> bool {
        matches!(byte, b'*' | b'-' | b'.' | b'0' ..= b'9' | b'A' ..= b'Z' | b'_' | b'a' ..= b'z')
    }

    // Uppercase hex encode.
    #[allow(non_upper_case_globals, non_snake_case)]
    fn hex_encode_nibble(nib: u8) -> u8 {
        const b_0: i16 = b'0' as i16;
        const b_9: i16 = b'9' as i16;
        const b_A: i16 = b'A' as i16;

        let nib = nib as i16;
        let base = nib + b_0;
        // equiv: let gap_9A = if nib >= 10 { b'A' - b'9' - 1 } else { 0 };
        let gap_9A = ((b_9 - b_0 - nib) >> 8) & (b_A - b_9 - 1);
        (base + gap_9A) as u8
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
        #[track_caller]
        fn ok(
            input: &str,
            workspace_root: &str,
            expected_cargo_pkg_id_spec: &str,
            expected_nargo_pkg_id: &str,
        ) {
            let cargo_pkg_id = CargoPkgId::parse(input).unwrap();
            let actual_cargo_pkg_id_spec = cargo_pkg_id.to_pkg_id_spec();
            let actual_nargo_pkg_id = nargo::PkgId::try_from_cargo_pkg_id(
                &actual_cargo_pkg_id_spec,
                workspace_root,
            );
            assert_eq!(
                (actual_cargo_pkg_id_spec.as_str(), actual_nargo_pkg_id.0),
                (expected_cargo_pkg_id_spec, expected_nargo_pkg_id),
                "input: {input:?}"
            );
        }

        ok(
            "unicode-ident 1.0.12 (registry+https://github.com/rust-lang/crates.io-index)",
            "",
            "registry+https://github.com/rust-lang/crates.io-index#unicode-ident@1.0.12",
            "#unicode-ident@1.0.12",
        );
        ok(
            "nargo-metadata 0.1.0 (path+file:///home/phlip9/dev/nargo/crates/nargo-metadata)",
            "/home/phlip9/dev/nargo",
            "path+file:///home/phlip9/dev/nargo/crates/nargo-metadata#0.1.0",
            "crates/nargo-metadata#0.1.0",
        );
        ok(
            "dependencies 0.0.0 (path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source)",
            "/nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source",
            "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0",
            "dependencies@0.0.0",
        );
        ok(
            "semver 1.0.12 (registry+https://github.com/rust-lang/crates.io-index)",
            "",
            "registry+https://github.com/rust-lang/crates.io-index#semver@1.0.12",
            "#semver@1.0.12",
        );
        ok(
            "semver 1.0.0 (git+https://github.com/dtolnay/semver?tag=1.0.0#a2ce5777dcd455246e4650e36dde8e2e96fcb3fd)",
            "",
            "git+https://github.com/dtolnay/semver?tag=1.0.0#1.0.0",
            "git+https://github.com/dtolnay/semver?tag=1.0.0#1.0.0",
        );
        ok(
            "semver 1.0.12 (git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7)",
            "",
            "git+http://github.com/dtolnay/semver?branch=master#1.0.12",
            "git+http://github.com/dtolnay/semver?branch=master#1.0.12",
        );
        ok(
            "semver 1.0.0 (git+ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd#a2ce5777dcd455246e4650e36dde8e2e96fcb3fd)",
            "",
            "git+ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd#1.0.0",
            "git+ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd#1.0.0",
        );
        ok(
            "semver 1.0.12 (git+ssh://git@github.com/dtolnay/semver#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7)",
            "",
            "git+ssh://git@github.com/dtolnay/semver#1.0.12",
            "git+ssh://git@github.com/dtolnay/semver#1.0.12",
        );
        ok(
            "world 0.2.0 (git+https://github.com/ipetkov/crane-test-repo?branch=something/or/other#world@0.2.0)",
            "",
            "git+https://github.com/ipetkov/crane-test-repo?branch=something%2For%2Fother#world@0.2.0",
            "git+https://github.com/ipetkov/crane-test-repo?branch=something%2For%2Fother#world@0.2.0",
        );
    }

    #[test]
    fn test_url() {
        #[track_caller]
        fn ok(input: &str, expected: Url<'_>) {
            let actual = Url::parse(input).unwrap();
            assert_eq!(actual, expected, "input: {input:?}");

            let actual_display = actual.to_string();
            let expected_display = expected.to_string();
            assert_eq!(input, actual_display);
            assert_eq!(input, expected_display);
        }

        ok(
            "registry+https://github.com/rust-lang/crates.io-index#unicode-ident@1.0.12",
            Url {
                scheme: "registry+https",
                authority_path: "github.com/rust-lang/crates.io-index",
                query: None,
                fragment: Some("unicode-ident@1.0.12"),
            }
        );
        ok(
            "path+file:///home/phlip9/dev/nargo/crates/nargo-metadata",
            Url {
                scheme: "path+file",
                authority_path: "/home/phlip9/dev/nargo/crates/nargo-metadata",
                query: None,
                fragment: None,
            },
        );
        ok(
            "git+https://github.com/dtolnay/semver?tag=1.0.0#a2ce5777dcd455246e4650e36dde8e2e96fcb3fd",
            Url {
                scheme: "git+https",
                authority_path: "github.com/dtolnay/semver",
                query: Some("tag=1.0.0"),
                fragment: Some("a2ce5777dcd455246e4650e36dde8e2e96fcb3fd"),
            },
        );
        ok(
            "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7",
            Url {
                scheme: "git+http",
                authority_path: "github.com/dtolnay/semver",
                query: Some("branch=master"),
                fragment: Some("a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7"),
            },
        );
        ok(
            "git+ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd#a2ce5777dcd455246e4650e36dde8e2e96fcb3fd",
            Url {
                scheme: "git+ssh",
                authority_path: "git@github.com/dtolnay/semver",
                query: Some("rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd"),
                fragment: Some("a2ce5777dcd455246e4650e36dde8e2e96fcb3fd"),
            },
        );
        ok(
            "git+ssh://git@github.com/dtolnay/semver#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7",
            Url {
                scheme: "git+ssh",
                authority_path: "git@github.com/dtolnay/semver",
                query: None,
                fragment: Some("a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7"),
            },
        );
    }
}
