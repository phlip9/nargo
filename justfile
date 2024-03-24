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

smoketest:
    just workspace-manifests fd
    just diff-metadata-manifests fd fd-find
