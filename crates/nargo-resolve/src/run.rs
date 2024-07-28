use nargo_core::time;

use crate::{resolve::ResolveFeatures, unit_graph::UnitGraph};

pub fn run(
    unit_graph_bytes: &[u8],
    resolve_features_bytes: &[u8],
    host_target: &str,
    workspace_root: &str,
) {
    let unit_graph: UnitGraph<'_> = time!(
        "deserialize unit graph JSON",
        serde_json::from_slice(unit_graph_bytes).expect(
            "Failed to deserialize `cargo build --unit-graph` json output"
        ),
    );
    let cargo_pkg_id_map = unit_graph.build_pkg_id_map(workspace_root);
    let cargo_resolve_features =
        unit_graph.build_resolve_features(&cargo_pkg_id_map, host_target);

    dbg!(cargo_resolve_features
        .keys()
        .map(|pkg_id| pkg_id.0)
        .collect::<Vec<_>>());

    let _nargo_resolve_features: ResolveFeatures<'_> = time!(
        "deserialize resolve features JSON",
        serde_json::from_slice(resolve_features_bytes)
            .expect("Failed to deserialize nix eval'd `resolveFeatures` JSON"),
    );

    assert_eq!(
        unit_graph.version, 1,
        "cargo unit-graph version has changed"
    );
}
