mod unit_graph;

use unit_graph::UnitGraph;

pub fn run(input_bytes: &[u8]) {
    let input: UnitGraph<'_> = serde_json::from_slice(input_bytes)
        .expect("Failed to deserialize `cargo build --unit-graph` json output");

    assert_eq!(input.version, 1, "cargo unit-graph version has changed");
}
