//! Prefetching and pinning crates from crates.io using `nix store prefetch-file`.

use core::str;
use std::{
    borrow::Cow,
    path::Path,
    process::{self, Stdio},
};

use anyhow::{format_err, Context};
use nargo_core::which::which;
use serde::Deserialize;

use crate::output;

/// Use `nix` to prefetch all crates from crates.io and fill in the `hash` in
/// their respective [`output::Package`].
pub fn prefetch(output: &mut output::Metadata<'_>) {
    // crates.io deps that need prefetching
    let needs_prefetch = output
        .packages
        .iter_mut()
        .filter(|(_pkg_id, pkg)| pkg.is_crates_io() && pkg.hash.is_none());

    let nix = which("nix").expect("Couldn't find `nix` binary in `$PATH`");

    // TODO(phlip9): concurrency
    for (pkg_id, pkg) in needs_prefetch {
        eprintln!("prefetch: {pkg_id}");

        let out = nix_store_prefetch_file(&nix, pkg)
            .with_context(|| pkg_id.to_string())
            .expect("Failed to prefetch crate");

        let hash = out.hash;
        eprintln!("  -> \"{hash}\"");

        pkg.hash = Some(output::SriHash(Cow::Owned(hash)));
    }
}

/// Ask `nix` to prefetch a crate from crates.io, place it into the /nix/store,
/// and then return the content hash.
fn nix_store_prefetch_file(
    nix: &Path,
    pkg: &output::Package<'_>,
) -> anyhow::Result<NixPrefetchOutput> {
    let prefetch_name = pkg.prefetch_name();
    let prefetch_url = pkg.prefetch_url();

    let out = process::Command::new(nix)
        .args(["store", "prefetch-file"])
        .arg("--json")
        .arg("--unpack")
        .args(["--hash-type", "sha256"])
        .args(["--name", prefetch_name.as_str()])
        .arg(prefetch_url.as_str())
        // TODO(phlip9): do something better
        .stderr(Stdio::inherit())
        .output()
        .context("Failed to run `nix store prefetch-file`")?;

    let stdout = str::from_utf8(&out.stdout)
        .context("`nix store prefetch-file` output is not valid UTF-8")?;

    if !out.status.success() {
        let status = &out.status;
        return Err(format_err!(
            "`nix store prefetch-file` process errored: {status}, stdout:\n{stdout}"
        ));
    }

    let out: NixPrefetchOutput = serde_json::from_str(stdout)
        .with_context(|| format!("Failed to deserialize `nix store prefetch-file output`: '{stdout}'"))?;

    Ok(out)
}

#[derive(Deserialize)]
struct NixPrefetchOutput {
    pub hash: String,
    // storePath: ...
}

#[cfg(test)]
mod test {
    use std::{borrow::Cow, collections::BTreeMap};

    use super::*;

    use crate::input::Source;

    #[ignore]
    #[test]
    fn test_nix_prefetch() {
        let nix = which("nix").unwrap();

        let pkg = output::Package {
            name: "anyhow",
            version: semver::Version::parse("1.0.81").unwrap(),
            source: Some(Source::CRATES_IO),
            hash: None,
            edition: "2018",

            rust_version: None,
            default_run: None,
            links: None,
            features: Cow::Owned(BTreeMap::new()),
            deps: BTreeMap::new(),
            targets: Vec::new(),
        };

        let out = nix_store_prefetch_file(&nix, &pkg).unwrap();

        assert_eq!(
            out.hash,
            "sha256-U7BJ1AxtArqA/yMIgPn62rocxs+YSfsgLAwu60ezZ7o=",
        );
    }
}
