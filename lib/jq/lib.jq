# Arguments from jq invocation:
#
#   $src : workspace source directory

# From an object, filter out all entries where the value is `null`
def filterNonNull: with_entries(select(.value != null));

def indexBy(f):
    .
    | sort_by(f)
    | INDEX(f)
    | map_values(del(f))
    ;

def cleanCratesRegistry:
    .
    | sub("^registry\\+https://github\\.com/rust-lang/crates\\.io-index"; "crates-io")
    ;

# ex: "path+file:///nix/store/6y9xxx3m6a1gs9807i2ywz9fhp6f8dm9-source/age#0.10.0" -> "age#0.10.0"
# ex: "registry+https://github.com/rust-lang/crates.io-index#aes-gcm@0.10.3" -> "crates-io#aes-gcm@0.10.3"
# ex: "path+file:///nix/store/7ph245lhiqzngqqkgrfnd4cdrzi08p4g-source#dependencies@0.0.0" -> "#dependencies@0.0.0"
def cleanPkgId:
    .
    | if (startswith("registry+")) then
        # shorten the standard crates.io registry url
        cleanCratesRegistry
      elif (startswith ("path+file://")) then
        # remove source paths
        (ltrimstr("path+file://\($src)") | ltrimstr("/"))
      else
        .
      end
    ;

# Clean a single target in a package manifest.
def cleanPkgManifestTarget($isWorkspacePkg; $manifestDir):
    .
    | {
        name: .name,
        kind: .kind,
        crate_types: .crate_types,
        src_path: .src_path | ltrimstr($manifestDir),
        edition: .edition,
        required_features: .required_features,
      }
    # Remove irrelevant targets from non-workspace crates
    | select(
        $isWorkspacePkg
        or (.kind | any(. == "lib" or . == "proc-macro" or . == "custom-build"))
      )
    | filterNonNull
    ;

# Clean a package manifest's targets.
def cleanPkgManifestTargets($isWorkspacePkg; $manifestDir):
    .
    | map(cleanPkgManifestTarget($isWorkspacePkg; $manifestDir))
    # Unfortunately, the `cargo metadata` output for package targets is
    # non-deterministic (read: filesystem dependent), so we need to sort them
    # first.
    | sort_by(.kind, .crate_types, .name)
    ;

def cleanPkgSource:
    .
    | if . != null then cleanCratesRegistry
      else null end
    ;

def cleanPkgPath:
    .
    | if . != null then (ltrimstr($src) | ltrimstr("/")) else . end
    ;

# Clean a single dependency entry in a package manifest.
def cleanPkgManifestDep($isWorkspacePkg):
    .
    | .source = (.source | cleanPkgSource)
    | .path = (.path | cleanPkgPath)
    # Remove dev-dependencies from non-workspace package manifests
    | select($isWorkspacePkg or (.kind != "dev"))
    | filterNonNull
    ;

# Clean all dependency entries in a package manifest.
def cleanPkgManifestDeps($isWorkspacePkg):
    .
    | map(cleanPkgManifestDep($isWorkspacePkg))
    ;

# Clean a single package manifest.
# A package manifest is effectively a deserialized `Cargo.toml` with some light
# processing.
def cleanPkgManifest:
    .
    | (.source == null) as $isWorkspacePkg
    | (.manifest_path | rtrimstr("Cargo.toml")) as $manifestDir
    | {
        name: .name,
        version: .version,
        id: .id | cleanPkgId,
        source: .source | cleanPkgSource,
        links: .links,
        default_run: .default_run,
        rust_version: .rust_version,
        edition: .edition,
        features: .features,
        dependencies: .dependencies | cleanPkgManifestDeps($isWorkspacePkg),
        targets: .targets | cleanPkgManifestTargets($isWorkspacePkg; $manifestDir),
      }
    | filterNonNull
    ;

# Clean all package manifests
def cleanPkgManifests:
    .
    | map(cleanPkgManifest)
    | indexBy(.id)
    ;

def cleanPkgDepKinds:
    .
    | map(filterNonNull) # | select(length > 0))
    # | select(length > 0)
    ;

def cleanPkgDep:
    .
    | {
        name: .name,
        id: .pkg | cleanPkgId,
        dep_kinds: .dep_kinds | cleanPkgDepKinds,
      }
    ;

def cleanPkgDeps:
    .
    | map(cleanPkgDep)
    | indexBy(.id)
    ;

def cleanPkg:
    .
    | {
        id: .id | cleanPkgId,
        # dependencies: .dependencies | map(cleanPkgId) | sort,
        deps: .deps | cleanPkgDeps,
      }
    ;

# Clean `cargo metadata` resolved packages
def cleanPkgs:
    .
    | map(cleanPkg)
    # | indexBy(.id)
    ;

def cleanWorkspaceMembers:
    .
    | map(cleanPkgId)
    | sort
    ;

def enrichPkg($manifests):
    .
    | $manifests[.id] as $manifest
    | {
        id: .id,
        name: $manifest.name,
        version: $manifest.version,
        default_run: $manifest.default_run,
        links: $manifest.links,
        rust_version: $manifest.rust_version,
        edition: $manifest.edition,
        features: $manifest.features,
        deps: .deps,
        targets: $manifest.targets,
      }
    | filterNonNull
    ;

def enrichPkgs($manifests):
    .
    | map(enrichPkg($manifests))
    | indexBy(.id)
    ;

# Generate `Cargo.metadata.json`
def genCargoMetadata:
    .
    # Start by cleaning most of the structs of irrelevant info, cleaning up
    # the pkgId's, indexing pkgs and manifests so they are
    # `Map<PackageId, Package>`.
    | {
        workspace_members: .workspace_members | cleanWorkspaceMembers,
        workspace_default_members: .workspace_default_members | cleanWorkspaceMembers,
        pkgs: (.resolve.nodes | cleanPkgs),
        manifests: (.packages | cleanPkgManifests),
      }
    # Next we're going to enrich each item in `pkgs` with relevant info from
    # their respective manifests. After this step, we don't need `manifests`
    # anymore.
    | .manifests as $manifests
    | {
        workspace_members: .workspace_members,
        workspace_default_members: .workspace_default_members,
        pkgs: .pkgs | enrichPkgs($manifests),
        # hold on to this for now while debugging
        manifests: .manifests,
      }
    ;
