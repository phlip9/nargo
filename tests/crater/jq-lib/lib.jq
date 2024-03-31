# Return an ordering for each target kind (0 is first, 5 is last).
def targetKindOrder:
    if . == "lib" then 0
    elif . == "bin" then 1
    elif . == "example" then 2
    elif . == "test" then 3
    elif . == "bench" then 4
    elif . == "build" then 5
    else halt_error end
    ;

# Clean a package's targets by sorting them.
def cleanPkgTargets:
    .
    | sort_by((.kind[0] | targetKindOrder), .name)
    ;

# Clean a single package manifest json
def cleanPkgManifest:
    .
    # Unfortunately, the `cargo metadata` output for package targets is
    # non-deterministic (read: filesystem dependent), so we need to sort them
    # first.
    | .targets = (.targets | cleanPkgTargets)
    ;

# Clean `cargo metadata` .packages
def cleanCargoMetadataPkgs:
    .
    | map(
        select(.source == null)
        | cleanPkgManifest
        | { (.name): . }
    )
    | add
    ;

def cleanNocargoMetadataPkgs:
    . 
    | map_values(cleanPkgManifest)
    ;
