use std::{
    collections::BTreeSet,
    io::{self, Write},
};

use crate::{clean, input, output};

pub fn run(workspace_src: &str, input_bytes: &[u8]) {
    let mut input: input::Metadata<'_> = time!(
        "deserialize input",
        serde_json::from_slice(input_bytes)
            .expect("Failed to deserialize cargo metadata output")
    );

    {
        let mut all_ids = BTreeSet::new();
        for id in &input.workspace_members {
            all_ids.insert(id.0);
        }
        for id in &input.workspace_default_members {
            all_ids.insert(id.0);
        }
        for pkg in &input.packages {
            all_ids.insert(pkg.id.0);
        }
        for pkg in &input.resolve.nodes {
            all_ids.insert(pkg.id.0);
        }

        eprintln!("all_ids: {all_ids:#?}");
    }

    let ctx = clean::Context { workspace_src };
    time!("clean input", input.clean(ctx));

    {
        let mut all_ids = BTreeSet::new();
        for id in &input.workspace_members {
            all_ids.insert(id.0);
        }
        for id in &input.workspace_default_members {
            all_ids.insert(id.0);
        }
        for pkg in &input.packages {
            all_ids.insert(pkg.id.0);
        }
        for pkg in &input.resolve.nodes {
            all_ids.insert(pkg.id.0);
        }

        eprintln!("all_ids: {all_ids:#?}");
    }

    let output = output::Metadata::new();

    let buf = time!(
        "serialize output",
        serde_json::to_vec_pretty(&output)
            .expect("Failed to serialize output json")
    );
    io::stdout()
        .lock()
        .write_all(&buf)
        .expect("Failed to write output json");
}
