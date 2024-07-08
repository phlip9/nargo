use std::{
    collections::BTreeMap,
    io::{self, Write},
};

use crate::{
    clean,
    input::{self, PkgId},
    output,
};

pub fn run(workspace_src: &str, input_bytes: &[u8]) {
    let mut input: input::Metadata<'_> = time!(
        "deserialize input",
        serde_json::from_slice(input_bytes)
            .expect("Failed to deserialize cargo metadata output")
    );

    let before_num_pkgs = input.resolve.nodes.len();

    let ctx = clean::Context { workspace_src };
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

    let buf = time!("serialize output", {
        use serde::ser::Serialize;
        use serde_json::ser::{PrettyFormatter, Serializer};

        let mut buf: Vec<u8> = Vec::with_capacity(32 << 10);
        let formatter = PrettyFormatter::with_indent(b" ");
        let mut serialier = Serializer::with_formatter(&mut buf, formatter);
        output
            .serialize(&mut serialier)
            .expect("Failed to serialize output json");
        buf
    });

    time!("write output", {
        let mut stdout = io::stdout().lock();
        stdout.write_all(&buf).expect("Failed to write output json");
        stdout.flush().expect("Failed to flush stdout");
    });
}
