use std::io::{self, Write};

use crate::{clean, input, output};

pub fn run(workspace_src: &str, input_bytes: &[u8]) {
    let input: input::Metadata<'_> = time!(
        "deserialize input",
        serde_json::from_slice(input_bytes)
            .expect("Failed to deserialize cargo metadata output")
    );

    let ctx = clean::Context { workspace_src };
    let output =
        time!("build output", output::Metadata::from_input(input, ctx));

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
