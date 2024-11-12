use std::{collections::BTreeMap, path::Path};

use nargo_core::{fs, time};

use crate::{
    clean,
    input::{self, PkgId},
    output, prefetch,
};

pub(crate) struct Args<'a> {
    pub input_raw_metadata_bytes: &'a [u8],
    pub input_current_metadata_bytes: Option<&'a [u8]>,
    pub output_metadata: Option<&'a Path>,
    pub nix_prefetch: bool,
    pub assume_vendored: bool,
}

pub fn run(args: Args<'_>) {
    let mut input: input::Metadata<'_> = time!(
        "deserialize `cargo metadata` output",
        serde_json::from_slice(args.input_raw_metadata_bytes)
            .expect("Failed to deserialize cargo metadata output")
    );

    let input_current_metadata: Option<output::Metadata<'_>> =
        args.input_current_metadata_bytes.map(|bytes| {
            time!(
                "deserialize current Cargo.metadata.json",
                serde_json::from_slice(bytes).expect(
                    "Failed to deserialize current Cargo.metadata.json"
                ),
            )
        });

    let before_num_pkgs = input.resolve.nodes.len();

    let workspace_root = input.workspace_root;
    let ctx = clean::Context { workspace_root };
    time!("clean input", input.clean(ctx));

    let manifests: BTreeMap<PkgId<'_>, input::Manifest<'_>> = input
        .packages
        .into_iter()
        .map(|pkg| (pkg.id, pkg))
        .collect();

    let mut output = time!(
        "build output",
        output::Metadata::from_input(
            ctx,
            &manifests,
            input.workspace_members,
            input.workspace_default_members,
            input.resolve,
            input_current_metadata.as_ref(),
            args.assume_vendored,
        ),
    );

    let after_num_pkgs = output.packages.len();
    assert_eq!(after_num_pkgs, before_num_pkgs);

    if args.nix_prefetch {
        time!("prefetch", prefetch::prefetch(&mut output));
    }

    let buf = time!("serialize output", output.serialize_pretty());

    time!(
        "write output",
        fs::write_file_or_stdout(args.output_metadata, &buf)
            .expect("Failed to write output")
    );
}
