metadata pkg:
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

diff-metadata-manifests pkg crate:
    diff -u --color=always \
        <(jq -S '.packages[] | select(.name == "{{ crate }}")' "{{ pkg }}.cargo-metadata.json") \
        <(jq -S '."{{ crate }}"' "{{ pkg }}.workspace-manifests.json")

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

smoketest:
    just smoketest-pkg features
    just smoketest-pkg fd
    just smoketest-pkg workspace-inline
    just smoketest-pkg pkg-targets
