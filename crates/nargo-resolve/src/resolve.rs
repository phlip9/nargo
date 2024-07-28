//! Types for `nix eval --json` of `lib/resolve.nix::resolveFeatures`.

#![allow(dead_code)]

use core::fmt;
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[derive(Deserialize, Serialize)]
pub struct PkgId<'a>(pub &'a str);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FeatFor {
    Build,
    Normal,
}

pub type ResolveFeatures<'a> = BTreeMap<PkgId<'a>, ByFeatFor<'a>>;

pub type ByFeatFor<'a> = BTreeMap<FeatFor, PkgFeatForActivation<'a>>;

#[derive(Deserialize, Serialize)]
pub struct PkgFeatForActivation<'a> {
    #[serde(borrow)]
    pub feats: BTreeMap<&'a str, ()>,
    //
    // // TODO
    // #[serde(borrow)]
    // pub deps: BTreeMap<&'a str, ()>,
    //
    // // TODO
    // pub deferred: serde::de::IgnoredAny,
}

// --- impl PkgId --- //

impl<'a> fmt::Display for PkgId<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

// --- impl FeatFor --- //

impl FeatFor {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Build => "build",
            Self::Normal => "normal",
        }
    }
}

impl fmt::Display for FeatFor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
