use assert_json_diff::{CompareMode, assert_json_matches_no_panic};
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
    assert_eq!(
        unit_graph.version, 1,
        "cargo unit-graph version has changed"
    );

    let cargo_pkg_id_map = unit_graph.build_pkg_id_map(workspace_root);
    let cargo_resolve_features = time!(
        "cargo resolve features",
        unit_graph.build_resolve_features(&cargo_pkg_id_map, host_target)
    );

    let nargo_resolve_features: ResolveFeatures<'_> = time!(
        "deserialize nargo resolve features JSON",
        serde_json::from_slice(resolve_features_bytes)
            .expect("Failed to deserialize nix eval'd `resolveFeatures` JSON"),
    );

    time!(
        "compare",
        compare_resolve_features(
            &nargo_resolve_features,
            &cargo_resolve_features,
        ),
    );
}

fn compare_resolve_features(
    nargo_resolve_features: &ResolveFeatures<'_>,
    cargo_resolve_features: &ResolveFeatures<'_>,
) {
    let result = assert_json_matches_no_panic(
        nargo_resolve_features,
        cargo_resolve_features,
        assert_json_diff::Config::new(CompareMode::Strict),
    );

    if let Err(diff_msg) = result {
        let nargo_json =
            serde_json::to_string_pretty(nargo_resolve_features).unwrap();
        let cargo_json =
            serde_json::to_string_pretty(cargo_resolve_features).unwrap();

        panic!(
            "feature resolution mismatch b/w nargo and cargo:
#
# nargo:
#
```json
{nargo_json}
```
#
# cargo:
#
```json
{cargo_json}
```
#
# diff:
#
{diff_msg}
#"
        );
    }
}
