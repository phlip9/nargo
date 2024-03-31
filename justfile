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

cargo-metadata pkg:
    nix build .#crater.x86_64-linux."{{ pkg }}".metadata
    cat ./result \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.cargo-metadata.json"

workspace-manifests pkg:
    nix eval --json --read-only --show-trace .#crater.x86_64-linux."{{ pkg }}".workspacePkgManifests \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.workspace-manifests.json"

workspace-manifests-verbose pkg:
    nix eval --json --read-only --show-trace --debug .#crater.x86_64-linux."{{ pkg }}".workspacePkgManifests \
        2> /dev/stdout \
        1> /dev/null

workspace-manifests-dbg-copies pkg:
    nix eval --json --read-only --show-trace --debug .#crater.x86_64-linux."{{ pkg }}".workspacePkgManifests \
        2> /dev/stdout \
        1> /dev/null \
        | grep "copied"

diff-metadata-manifest pkg crate:
    diff -u --color=always \
        <(jq -S '.packages[] | select(.name == "{{ crate }}")' "{{ pkg }}.cargo-metadata.json") \
        <(jq -S '."{{ crate }}"' "{{ pkg }}.workspace-manifests.json")

diff-metadata-manifests pkg:
    diff -u --color=always \
        <(jq -S '.packages | map(select(.source == null) | { (.name): . }) | add' "{{ pkg }}.cargo-metadata.json") \
        <(jq -S '.' "{{ pkg }}.workspace-manifests.json")

smoketest2:
    # just smoketest-pkg2 features simple-features
    # just smoketest-pkg2 fd fd-find
    # just smoketest-pkg2 workspace-inline bar
    just smoketest-pkg2 pkg-targets pkg-targets

smoketest-pkg2 pkg crate:
    just metadata {{ pkg }}
    just workspace-manifests {{ pkg }}
    just diff-metadata-manifests {{ pkg }} {{ crate }}

smoketest-pkg pkg:
    nix build -L --show-trace .#crater.x86_64-linux."{{ pkg }}".diffPkgManifests

smoketest-pkg-dbg pkg:
    nix build -L --show-trace --debugger --impure --ignore-try \
        .#crater.x86_64-linux."{{ pkg }}".diffPkgManifests

smoketest:
    just smoketest-pkg features
    just smoketest-pkg workspace-inline
    just smoketest-pkg pkg-targets
    just smoketest-pkg fd
    just smoketest-pkg rage
    just smoketest-pkg ripgrep
    just smoketest-pkg hickory-dns
    just smoketest-pkg cargo-hack

test:
    nix eval --read-only --show-trace \
        .#crater.x86_64-linux.tests
