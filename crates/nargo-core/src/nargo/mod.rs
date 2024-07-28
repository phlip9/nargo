//! nargo types

use anyhow::Context as _;
use serde::{Deserialize, Serialize};

const CRATES_IO_REGISTRY: &str =
    "registry+https://github.com/rust-lang/crates.io-index";

#[derive(Copy, Clone, Ord, PartialOrd, Eq, PartialEq, Deserialize, Serialize)]
#[cfg_attr(test, derive(Debug))]
pub struct PkgId<'a>(pub &'a str);

impl<'a> PkgId<'a> {
    pub fn try_from_cargo_pkg_id<'b>(
        id: &'a str,
        workspace_root: &'b str,
    ) -> Self {
        Self::try_from_cargo_pkg_id_inner(id, workspace_root)
            .with_context(|| id.to_owned())
            .expect("Failed to convert serialized cargo PackageIdSpec")
    }

    fn try_from_cargo_pkg_id_inner<'b>(
        id: &'a str,
        workspace_root: &'b str,
    ) -> Option<Self> {
        // ex: "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0"
        //  -> "age#0.10.0"
        // ex: "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0"
        // -> "dependencies@0.0.0"
        if let Some(rest) = id.strip_prefix("path+file://") {
            let rest = rest.strip_prefix(workspace_root)?;
            let rest = rest.trim_start_matches(['#', '/']);
            return Some(Self(rest));
        }

        // ex: "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3"
        // -> "#aes-gcm@0.10.3"
        if let Some(rest) = id.strip_prefix(CRATES_IO_REGISTRY) {
            return Some(Self(rest));
        }

        // ex: (unchanged) "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7"
        Some(Self(id))
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_pkg_id_try_from_cargo_pkg_id() {
        let workspace_root =
            "/nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source";
        let id = "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0";
        let id_clean = PkgId::try_from_cargo_pkg_id_inner(id, workspace_root);
        assert_eq!(id_clean, Some(PkgId("age#0.10.0")));

        let workspace_root =
            "/nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source";
        let id = "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0";
        let id_clean = PkgId::try_from_cargo_pkg_id_inner(id, workspace_root);
        assert_eq!(id_clean, Some(PkgId("dependencies@0.0.0")));

        let id = "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3";
        let id_clean = PkgId::try_from_cargo_pkg_id_inner(id, workspace_root);
        assert_eq!(id_clean, Some(PkgId("#aes-gcm@0.10.3")));

        let id = "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7";
        let id_clean = PkgId::try_from_cargo_pkg_id_inner(id, workspace_root);
        assert_eq!(id_clean, Some(PkgId(id)));
    }
}
