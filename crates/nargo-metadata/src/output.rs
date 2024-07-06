#![allow(dead_code)]

use std::collections::BTreeMap;

use serde::Serialize;

#[derive(Serialize)]
pub(crate) struct Metadata {
    packages: BTreeMap<String, String>,
}

impl Metadata {
    pub(crate) fn new() -> Self {
        Self {
            packages: BTreeMap::new(),
        }
    }
}
