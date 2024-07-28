// a

use serde::Deserialize;

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
    pub target: UnitTarget,
    pub profile: UnitProfile,
    pub platform: &'a str,
    pub mode: &'a str,
    #[serde(borrow)]
    pub features: Vec<&'a str>,
    pub dependencies: Vec<UnitDep>,
}

#[derive(Deserialize)]
pub struct UnitTarget {
    // TODO
}

#[derive(Deserialize)]
pub struct UnitProfile {
    // TODO
}

#[derive(Deserialize)]
pub struct UnitDep {
    // TODO
}

// --- run --- //

pub fn run(input_bytes: &[u8]) {
    let input: UnitGraph<'_> = serde_json::from_slice(input_bytes)
        .expect("Failed to deserialize `cargo build --unit-graph` json output");

    assert_eq!(input.version, 1, "cargo unit-graph version has changed");
}
