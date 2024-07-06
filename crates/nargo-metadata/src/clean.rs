use anyhow::Context as _;

use crate::input::{self, DepKind, PkgId};

const CRATES_IO_REGISTRY: &str = "registry+https://github.com/rust-lang/crates.io-index";

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
        self.workspace_members.sort_unstable();

        for id in &mut self.workspace_default_members {
            id.clean(ctx);
        }
        self.workspace_default_members.sort_unstable();

        self.resolve.clean(ctx);
    }
}

//
// --- impl Manifest ---
//

impl<'a> input::Manifest<'a> {
    fn clean(&mut self, ctx: Context<'a>) {
        self.id.clean(ctx);
        self.source.as_mut().map(input::Source::clean);

        self.clean_dependencies(ctx);
        self.clean_targets();
    }

    fn clean_dependencies(&mut self, ctx: Context<'a>) {
        // Remove dev-dependencies from non-workspace package manifests
        if !self.is_workspace_pkg() {
            self.dependencies.retain(|dep| dep.kind != DepKind::Dev);
        }

        for dependency in &mut self.dependencies {
            dependency.clean(self.id, ctx);
        }

        self.dependencies.sort_unstable_by(|d1, d2| {
            d1.name.cmp(d2.name)
            .then_with(|| d1.kind.cmp(&d2.kind))
                .then_with(|| d1.target.cmp(&d2.target))
        });
    }

    fn clean_targets(&mut self) {
        // Remove irrelevant targets (tests, benchmarks, examples) from
        // non-workspace crates.
        if !self.is_workspace_pkg() {
            self.targets.retain(|target| {
                target.kind.iter().any(|&kind| kind == "lib" || kind == "proc-macro" || kind == "custom-build")
            });
        }

        let manifest_dir = self.manifest_dir();
        for target in &mut self.targets {
            target.clean(self.id, manifest_dir);
        }

        // Unfortunately, the `cargo metadata` output for package targets is
        // non-deterministic (read: filesystem dependent), so we need to sort them
        // first.
        self.targets.sort_unstable_by(|t1, t2| {
            t1.kind.cmp(&t2.kind)
                .then_with(|| t1.crate_types.cmp(&t2.crate_types))
                .then_with(|| t1.name.cmp(t2.name))
        });
    }
}

//
// --- impl ManifestDependency ---
//

impl<'a> input::ManifestDependency<'a> {
    fn clean(&mut self, id: PkgId<'a>, ctx: Context<'a>) {
        self.source.as_mut().map(input::Source::clean);

        if let Some(path) = self.path.as_mut() {
            *path = path.strip_prefix(ctx.workspace_src)
                .with_context(|| format!(
                    "A workspace Cargo.toml's path dependency points outside the workspace:\n\
                             dep.name: '{}'\n\
                             dep.path: '{path}'\n\
                          manifest id: '{id}'\n\
                        workspace_src: '{}'\n\
                    ",
                    self.name,
                    ctx.workspace_src,
                ))
                .unwrap()
                .trim_start_matches('/');
        }
    }
}

//
// --- impl ManifestTarget ---
//

impl<'a> input::ManifestTarget<'a> {
    fn clean(
        &mut self,
        id: PkgId<'a>,
        manifest_dir: &'a str,
    ) {
        let src_path = self.src_path;

        self.src_path = 
            src_path
            .strip_prefix(manifest_dir)
            .with_context(|| format!(
                "A Cargo.toml's target src_path is outside the crate directory:\n\
                     src_path: '{src_path}'\n\
                   package id: '{id}'\n\
                 ",
            ))
            .unwrap();
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
        if let Some(rest) = id.strip_prefix(CRATES_IO_REGISTRY) {
            return Some(rest);
        }

        // ex: (unchanged) "git+http://github.com/dtolnay/semver?branch=master#a6425e6f41ddc81c6d6dd60c68248e0f0ef046c7"
        Some(id)
    }
}

//
// --- impl Source ---
//

impl<'a> input::Source<'a> {
    fn clean(&mut self) {
        if self.0 == CRATES_IO_REGISTRY {
            self.0 = "crates.io-index"
        }
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
