# Arguments from jq invocation:
#
#   $src : workspace source directory

# From an object, filter out all entries where the value is `null`
def filterNonNull: with_entries(select(.value != null));

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
    ;

# Clean a package manifest's targets.
def cleanPkgManifestTargets($isWorkspacePkg; $manifestDir):
    .
    | map(cleanPkgManifestTarget($isWorkspacePkg; $manifestDir))
    # Unfortunately, the `cargo metadata` output for package targets is
    # non-deterministic (read: filesystem dependent), so we need to sort them
    # first.
    | sort_by(.kind, .name)
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
def cleanPkgManifestDep:
    .
    | .source = (.source | cleanPkgSource)
    | .path = (.path | cleanPkgPath)
    | filterNonNull
    ;

# Clean all dependency entries in a package manifest.
def cleanPkgManifestDeps:
    .
    | map(cleanPkgManifestDep)
    ;

# Clean a single package manifest.
# A package manifest is effectively a deserialized `Cargo.toml` with some light
# processing.
def cleanPkgManifest:
    (.source == null) as $isWorkspacePkg
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
        dependencies: .dependencies | cleanPkgManifestDeps,
        targets: .targets | cleanPkgManifestTargets($isWorkspacePkg; $manifestDir),
      }
    | filterNonNull
    ;

# Clean all package manifests
def cleanPkgManifests:
    .
    | map(cleanPkgManifest)
    | sort_by(.id)
    | INDEX(.id)
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

def cleanPkg:
    .
    | {
        id: .id | cleanPkgId,
        dependencies: .dependencies | map(cleanPkgId) | sort,
        deps: .deps | map(cleanPkgDep) | sort_by(.id),
      }
    ;

# Clean `cargo metadata` resolved packages
def cleanPkgs:
    .
    | map(cleanPkg)
    | sort_by(.id)
    | INDEX(.id)
    ;

def cleanWorkspaceMembers:
    .
    | map(cleanPkgId)
    | sort
    ;

# Clean `cargo metadata` output
def cleanCargoMetadata:
    .
    # Start by cleaning most of the structs of irrelevant info, cleaning up
    # the pkgId's
    | {
        workspace_members: .workspace_members | cleanWorkspaceMembers,
        workspace_default_members: .workspace_default_members | cleanWorkspaceMembers,
        pkgs: (.resolve.nodes | cleanPkgs),
        manifests: (.packages | cleanPkgManifests),
      }
    ;


