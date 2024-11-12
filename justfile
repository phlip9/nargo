# auto-format the `justfile`
just-fmt:
    just --fmt --unstable

# Generate Cargo.metadata.json file
cargo-metadata-json:
    cargo metadata --format-version=1 --all-features \
        | cargo run -p nargo-metadata -- \
            --output-metadata Cargo.metadata.json

smoketest-pkg pkg:
    nix build -L --show-trace \
        .#tests.x86_64-linux.examples."{{ pkg }}".checkResolveFeatures

smoketest-pkg-dbg pkg:
    nix build -L --show-trace --debugger --impure --ignore-try \
        .#tests.x86_64-linux.examples."{{ pkg }}".checkResolveFeatures

smoketest:
    just smoketest-pkg features
    just smoketest-pkg workspace-inline
    just smoketest-pkg pkg-targets
    # just smoketest-pkg dependency-v3
    just smoketest-pkg fd
    just smoketest-pkg rage
    just smoketest-pkg ripgrep
    just smoketest-pkg hickory-dns
    just smoketest-pkg cargo-hack
    just smoketest-pkg rand

# Run nargo-resolve test on local workspace
nargo-resolve-workspace:
    cargo run -p nargo-resolve -- \
        --unit-graph <(just cargo-unit-graph) \
        --resolve-features <(just resolve-features) \
        --host-target x86_64-unknown-linux-gnu \
        --workspace-root $(pwd)

resolve-features:
    nix eval --json .#packages.x86_64-linux.nargo-metadata.resolved

# Emit `cargo build --unit-graph` for local workspace
cargo-unit-graph:
    RUSTC_BOOTSTRAP=1 cargo build --unit-graph \
        --target=x86_64-unknown-linux-gnu \
        --frozen \
        -Z unstable-options

# Emit `cargo build --build-plan` for local workspace
cargo-build-plan:
    RUSTC_BOOTSTRAP=1 cargo build --build-plan \
        --target=x86_64-unknown-linux-gnu \
        --frozen \
        --release \
        -Z unstable-options

cargo-metadata pkg:
    nix build .#tests.x86_64-linux.examples."{{ pkg }}".metadata
    cat ./result \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.cargo-metadata.json"

clean-cargo-metadata pkg:
    jq --sort-keys -L ./tests/crater/jq-lib '\
        import "lib" as lib; \
        .packages | lib::cleanCargoMetadataPkgs' \
        "{{ pkg }}.cargo-metadata.json"

clean-workspace-manifests pkg:
    jq --sort-keys -L ./tests/crater/jq-lib '\
        import "lib" as lib; \
        . | lib::cleanNocargoMetadataPkgs' \
        "{{ pkg }}.workspace-manifests.json"

diff-clean-metadata-manifests pkg:
    diff --unified=10 --color=always \
        <(just clean-cargo-metadata "{{ pkg }}") \
        <(just clean-workspace-manifests "{{ pkg }}")
