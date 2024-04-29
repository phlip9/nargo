# auto-format the `justfile`
just-fmt:
    just --fmt --unstable

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

workspace-pkg-infos pkg:
    nix eval --json --read-only --show-trace .#crater.x86_64-linux."{{ pkg }}".workspacePkgInfos \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.workspace-pkg-infos.json"

workspace-pkg-infos2 pkg:
    nix eval --json --read-only --show-trace .#crater.x86_64-linux."{{ pkg }}".workspacePkgInfos2 \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.workspace-pkg-infos2.json"

smoketest-pkg pkg:
    # nix build -L --show-trace .#crater.x86_64-linux."{{ pkg }}".diffPkgManifests
    nix build -L --show-trace .#crater.x86_64-linux."{{ pkg }}".diffPkgInfos

smoketest-pkg-dbg pkg:
    nix build -L --show-trace --debugger --impure --ignore-try \
        .#crater.x86_64-linux."{{ pkg }}".diffPkgManifests

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

test:
    nix eval --read-only --show-trace \
        .#crater.x86_64-linux.tests
