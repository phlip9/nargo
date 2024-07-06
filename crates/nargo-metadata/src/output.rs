use std::collections::BTreeMap;

use serde::Serialize;

use crate::{
    clean,
    input::{self, PkgId},
};

// type Manifests<'a> = BTreeMap<PkgId<'a>, input::Manifest<'a>>;

#[derive(Serialize)]
pub struct Metadata<'a> {
    pub workspace_members: Vec<PkgId<'a>>,
    pub workspace_default_members: Vec<PkgId<'a>>,
    pub packages: BTreeMap<PkgId<'a>, Package<'a>>,
}

#[derive(Serialize)]
pub struct Package<'a> {
    pub name: &'a str,
}

//
// --- impl Metadata ---
//

impl<'a> Metadata<'a> {
    pub fn from_input<'ctx: 'a>(
        mut input: input::Metadata<'a>,
        ctx: clean::Context<'ctx>,
    ) -> Self {
        time!("clean input", input.clean(ctx));

        let manifests: BTreeMap<PkgId<'_>, input::Manifest<'_>> = input
            .packages
            .into_iter()
            .map(|pkg| (pkg.id, pkg))
            .collect();

        let packages: BTreeMap<PkgId<'_>, Package<'_>> = input
            .resolve
            .nodes
            .into_iter()
            .map(|pkg| {
                (
                    pkg.id,
                    Package {
                        name: manifests[&pkg.id].name,
                    },
                )
            })
            .collect();

        Metadata {
            workspace_members: input.workspace_members,
            workspace_default_members: input.workspace_default_members,
            packages,
        }
    }
}
