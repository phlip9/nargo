# Arguments from jq invocation:
#
#   $src : source directory
#   $cargoVendorDir : vendored crates directory

def cleanCratesRegistry:
    .
    | sub("^registry\\+https://github\\.com/rust-lang/crates\\.io-index"; "registry+crates.io")
    ;

def cleanPkgSource:
    .
    | if . != null then cleanCratesRegistry
      else null end
    ;

def cleanPkgPath:
    .
    | if . != null then (. | split($src) | join("src"))
      else null end
    ;

def cleanPkgId:
    .
    # remove source paths
    | split("path+file://\($src)/") | join("path+file://")
    # shorten crates.io registry
    | cleanCratesRegistry
    ;

def cleanPkgTargetSrcPath:
    .
    | ltrimstr("\($src)/")
    | if (startswith("\($cargoVendorDir)/"))
      then (ltrimstr("\($cargoVendorDir)/") | split("/") | .[2:] | join("/"))
      else . end
    ;

# Clean a single target in a package.
def cleanPkgTarget($isWorkspacePkg):
    .
    | {
        name: .name,
        kind: .kind[0],
        crate_types: .crate_types[0],
        src_path: .src_path,# | cleanPkgTargetSrcPath,
        edition: .edition,
        required_features: .required_features,
      }
    # Remove irrelevant targets from non-workspace crates
    | select($isWorkspacePkg or .kind == "lib" or .kind == "proc-macro" or .kind == "custom-build")
    ;

# Clean a package's targets.
def cleanPkgTargets($isWorkspacePkg):
    .
    | map(cleanPkgTarget($isWorkspacePkg))
    # Unfortunately, the `cargo metadata` output for package targets is
    # non-deterministic (read: filesystem dependent), so we need to sort them
    # first.
    | sort_by(.kind, .name)
    ;

# Clean a single dependency entry in a package
def cleanPkgDependency:
    .
    # | .source = (.source | cleanPkgSource)
    # | .path = (.path | cleanPkgPath)
    | with_entries(select(.value != null))
    ;

# Clean all dependency entries in a package
def cleanPkgDependencies:
    .
    | map(cleanPkgDependency)
    ;

# Clean a single package manifest
def cleanPkgManifest:
    (.source == null) as $isWorkspacePkg
    | {
        name: .name,
        version: .version,
        id: .id,# | cleanPkgId,
        source: .source,# | cleanPkgSource,
        links: .links,
        default_run: .default_run,
        rust_version: .rust_version,
        edition: .edition,
        features: .features,
        dependencies: .dependencies | cleanPkgDependencies,
        targets: .targets | cleanPkgTargets($isWorkspacePkg),
      }
    | with_entries(select(.value != null))
    ;

# Clean `cargo metadata` .packages
def cleanPkgs:
    .
    | map(cleanPkgManifest)
    | sort_by(.name, .version, .id)
    ;

# Clean `cargo metadata` output
def cleanCargoMetadata:
    .
    | {
        packages: (.packages | cleanPkgs),
        version: .version,
      }
    ;
