use std::{
    collections::BTreeMap,
    io::{self, Write},
};

use nargo_core::time;

use crate::{
    clean,
    input::{self, PkgId},
    output,
};

pub fn run(input_bytes: &[u8]) {
    let mut input: input::Metadata<'_> = time!(
        "deserialize input",
        serde_json::from_slice(input_bytes)
            .expect("Failed to deserialize cargo metadata output")
    );

    let before_num_pkgs = input.resolve.nodes.len();

    let workspace_root = input.workspace_root;
    let ctx = clean::Context { workspace_root };
    time!("clean input", input.clean(ctx));

    let manifests: BTreeMap<PkgId<'_>, input::Manifest<'_>> = input
        .packages
        .into_iter()
        .map(|pkg| (pkg.id, pkg))
        .collect();

    let output = time!(
        "build output",
        output::Metadata::from_input(
            ctx,
            &manifests,
            input.workspace_members,
            input.workspace_default_members,
            input.resolve,
        )
    );

    let after_num_pkgs = output.packages.len();
    assert_eq!(after_num_pkgs, before_num_pkgs);

    let buf = time!("serialize output", output.serialize_pretty());

    time!("write output", {
        let mut stdout = io::stdout().lock();
        stdout.write_all(&buf).expect("Failed to write output json");
        stdout.flush().expect("Failed to flush stdout");
    });
}
