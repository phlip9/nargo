//! Types for `nix eval --json` of `lib/resolve.nix::resolveFeatures`.

#![allow(dead_code)]

use std::collections::BTreeMap;

use serde::Deserialize;

#[derive(Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct PkgId<'a>(&'a str);

#[derive(Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum FeatFor {
    Build,
    Normal,
}

pub type ResolveFeatures<'a> = BTreeMap<PkgId<'a>, ByFeatFor<'a>>;

pub type ByFeatFor<'a> = BTreeMap<FeatFor, PkgFeatForActivation<'a>>;

#[derive(Deserialize)]
pub struct PkgFeatForActivation<'a> {
    #[serde(borrow)]
    pub feats: BTreeMap<&'a str, ()>,

    #[serde(borrow)]
    pub deps: BTreeMap<&'a str, ()>,

    // TODO
    deferred: serde::de::IgnoredAny,
}
