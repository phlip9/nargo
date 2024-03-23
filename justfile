metadata pkg:
    nix build .#crater.x86_64-linux."{{ pkg }}".metadata
    cat ./result \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.cargo-metadata.json"

localsrcinfos pkg:
    nix eval --json --read-only --show-trace .#crater.x86_64-linux."{{ pkg }}".localSrcInfos \
        | jq -S . \
        | tee /dev/stderr \
        > "{{ pkg }}.localsrcinfos.json"

diff-metadata-localsrcinfos pkg crate:
    diff -u --color=always \
        <(jq -S '.packages[] | select(.name == "{{ crate }}")' "{{ pkg }}.cargo-metadata.json") \
        <(jq -S '."{{ crate }}"' "{{ pkg }}.localsrcinfos.json")
