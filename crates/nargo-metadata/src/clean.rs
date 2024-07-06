use anyhow::Context as _;

use crate::input;

#[derive(Copy, Clone)]
pub struct Context<'a> {
    pub workspace_src: &'a str,
}

//
// --- impl Metadata ---
//

impl<'a> input::Metadata<'a> {
    pub fn clean(&mut self, ctx: Context<'a>) {
        for package in &mut self.packages {
            package.clean(ctx);
        }

        for id in &mut self.workspace_members {
            id.clean(ctx);
        }

        for id in &mut self.workspace_default_members {
            id.clean(ctx);
        }

        self.resolve.clean(ctx);
    }
}

//
// --- impl Manifest ---
//

impl<'a> input::Manifest<'a> {
    fn clean(&mut self, ctx: Context<'a>) {
        self.id.clean(ctx);
    }
}

//
// --- impl Resolve ---
//

impl<'a> input::Resolve<'a> {
    fn clean(&mut self, ctx: Context<'a>) {
        for node in &mut self.nodes {
            node.clean(ctx);
        }
    }
}

//
// --- impl Node ---
//

impl<'a> input::Node<'a> {
    fn clean(&mut self, ctx: Context<'a>) {
        self.id.clean(ctx);

        for dep in &mut self.deps {
            dep.clean(ctx);
        }
    }
}

//
// --- impl NodeDep ---
//

impl<'a> input::NodeDep<'a> {
    fn clean(&mut self, ctx: Context<'a>) {
        self.pkg.clean(ctx);
    }
}

//
// --- impl PkgId ---
//

impl<'a> input::PkgId<'a> {
    fn clean(&mut self, ctx: Context<'a>) {
        let id = self.0;
        self.0 = Self::clean_inner(id, ctx)
            .with_context(|| "Failed to clean package id: '{id}'")
            .unwrap();
    }

    fn clean_inner<'id>(id: &'id str, ctx: Context<'a>) -> Option<&'id str> {
        // ex: "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0"
        //  -> "age#0.10.0"
        // ex: "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0"
        // -> "dependencies@0.0.0"
        if let Some(rest) = id.strip_prefix("path+file://") {
            let rest = rest.strip_prefix(ctx.workspace_src)?;
            let rest = rest.trim_start_matches(['#', '/']);
            return Some(rest);
        }

        // ex: "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3"
        // -> "#aes-gcm@0.10.3"
        if let Some(rest) = id.strip_prefix(
            "registry+https://github.com/rust-lang/crates.io-index",
        ) {
            return Some(rest);
        }

        // ex: (unchanged) "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7"
        Some(id)
    }
}

#[cfg(test)]
mod test {
    use crate::{clean::Context, input::PkgId};

    #[test]
    fn test_pkg_id_clean() {
        let ctx = Context {
            workspace_src: "/nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source",
        };
        let id = "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0";
        let id_clean = PkgId::clean_inner(id, ctx);
        assert_eq!(id_clean, Some("age#0.10.0"));

        let ctx = Context {
            workspace_src: "/nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source",
        };
        let id = "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0";
        let id_clean = PkgId::clean_inner(id, ctx);
        assert_eq!(id_clean, Some("dependencies@0.0.0"));

        let id = "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3";
        let id_clean = PkgId::clean_inner(id, ctx);
        assert_eq!(id_clean, Some("#aes-gcm@0.10.3"));

        let id = "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7";
        let id_clean = PkgId::clean_inner(id, ctx);
        assert_eq!(id_clean, Some(id));
    }
}
