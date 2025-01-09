alias nm := nargo-metadata
alias rl := rust-lint
alias rt := rust-test

# Generate `Cargo.metadata.json` file
nargo-metadata *args:
    cargo run -p nargo-metadata -- --verbose {{ args }}

# Check that `Cargo.metadata.json` file remains unchanged
nargo-metadata-check *args:
    just nargo-metadata --check {{ args }}

smoketest-pkg pkg:
    nix build -L --show-trace \
        .#tests.x86_64-linux.examples."{{ pkg }}".checkResolveFeatures

smoketest-pkg-dbg pkg:
    nix build -L --show-trace --debugger --impure --ignore-try \
        .#tests.x86_64-linux.examples."{{ pkg }}".checkResolveFeatures

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

# --- rust --- #

rust-lint *args:
    cargo clippy --workspace --all-targets {{ args }}
    cargo clippy -p nargo-rustc --bin nargo-rustc {{ args }}
    cargo clippy -p nargo-metadata --bin nargo-metadata {{ args }}

rust-fmt:
    cargo fmt --all

rust-fmt-check:
    cargo fmt --all --check

rust-test *args:
    cargo test --lib {{ args }}

# regenerate the Cargo.lock files in all tests/examples
rust-update-example-lockfiles:
    fd "Cargo.toml" tests/examples --threads=6 --exec \
        cargo generate-lockfile --manifest-path {}

# --- just --- #

just-fmt:
    just --fmt --unstable

just-fmt-check:
    just --fmt --unstable --check

# --- nix --- #

nix-fmt:
    nix fmt -- .

nix-fmt-check:
    nix fmt -- --check .

nix-current-system:
    @nix eval --raw --impure --expr builtins.currentSystem

nix-fast-build *args:
    nix develop .#nix-test --command \
      nix-fast-build {{ args }}

nix-test *args:
    just nix-fast-build --no-link --skip-cached \
        --flake .#checks.$(just nix-current-system) {{ args }}

# nix-test-ci:
#     # disable nix output monitor (nom) for CI-friendly output
#     just nix-test --no-nom

# build top-level packages in GitHub Actions CI
nix-build-gha-ci:
    nix build -L --no-link \
        .#nargo-rustc \
        .#nargo-metadata \
        '.#nargo-metadata.built."crates/nargo-metadata#0.1.0".normal.bin-nargo-metadata'

# --- bash --- #

shfmt-config := "--indent 2 --simplify --space-redirects --language-dialect bash"
shellcheck-config := "--shell=bash"

bash-fmt:
    nix develop .#bash-lint --command \
      fd --extension "sh" --exec-batch \
        shfmt {{ shfmt-config }} --list --write

bash-fmt-check:
    nix develop .#bash-lint --command \
      fd --extension "sh" --exec-batch \
        shfmt {{ shfmt-config }} --diff

bash-lint:
    nix develop .#bash-lint --command \
      fd --extension "sh" --exec-batch \
        shellcheck {{ shellcheck-config }}

# --- profiling/benchmarking --- #

nix-build-profiling drv:
    time -v nix build --rebuild --log-format internal-json --debug {{ drv }} 2>&1 \
        | ts -s -m "[%.s]" \
        > dump/nixprof.log

print-bind-mounts log:
    rg -o -r '$1' "sandbox setup: bind mounting '([^']+)' to '[^']+'" {{ log }}

print-file-evals log:
    rg -o -r '$1' "evaluating file '([^']+)'" {{ log }}

print-file-copies log:
    rg -o -r '$1' "copying '([^']+)'" {{ log }}

print-input-paths log:
    rg -o -r '$1' "added input paths ('.*')" {{ log }} \
        | sed -e 's/, /\n/g' \
        | sed -e "s/'\(.*\)'/\\1/g"

# bench building a single drv with warm caches
bench-drv-cached drv:
    nix build {{ drv }}
    hyperfine --warmup 3 --min-runs 3 'nix build --rebuild {{ drv }}'
    just nix-build-profiling {{ drv }}

# TODO(phlip9): bench building a single drv with cold caches

# get the current nix-daemon PID
nix-daemon-pid:
    @# ensure nix-daemon is running
    @nix store info 2> /dev/null
    @systemctl show nix-daemon.service -P MainPID

# check if the kernel allows all perf events
[linux]
perf-check-not-paranoid:
    @./just/perf-check-not-paranoid.sh

[macos]
[no-exit-message]
perf-check-not-paranoid:
    @echo >&2 "error: perf and samply are not supported on macOS"
    @exit 1

# tell kernel to allow all perf events (requires sudo)
perf-reduce-paranoia:
    echo "-1" | sudo tee /proc/sys/kernel/perf_event_paranoid
    echo "0" | sudo tee /proc/sys/kernel/kptr_restrict

# `retry nix build --rebuild --offline {{ drv }}`
nix-build-grind drv:
    @./just/nix-build-grind.sh {{ drv }}

# `perf` profile the background `nix-daemon` process
perf-nix-daemon:
    @./just/perf-nix-daemon.sh

# `samply` profile `nix $cmd`
samply-nix *cmd:
    @./just/samply-nix.sh {{ cmd }}

# `samply` profile `nix $cmd` and the nix-daemon in the background
samply-nix-and-daemon *cmd:
    @./just/samply-nix-and-daemon.sh {{ cmd }}

# samply load profile in browser
samply-load file="profile.nix.json.gz":
    samply load {{ file }}
