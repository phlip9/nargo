# auto-format the `justfile`
just-fmt:
    just --fmt --unstable

# Generate Cargo.metadata.json file
cargo-metadata-json:
    cargo metadata --format-version=1 --all-features \
        | cargo run -p nargo-metadata -- \
            --output-metadata Cargo.metadata.json \
            --nix-prefetch \
            --verbose

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
    #!/usr/bin/env bash
    set -euo pipefail

    eprintln() {
        echo >&2 "$1"
    }

    check() {
        file="$1"
        expected="$2"
        why="$3"
        if [[ ! -f "$file" ]]; then
            eprintln "error: can't find file $file"
            eprintln ""
            eprintln "suggestion: ensure your Linux kernel supports perf events"
            exit 1
        fi

        actual="$(< $file)"
        if [[ "$actual" != "$expected" ]]; then
            eprintln "error: you need to $why"
            eprintln ""
            eprintln "      file: $file"
            eprintln "    actual: $actual"
            eprintln "  expected: $expected"
            eprintln ""
            eprintln "suggestion: just perf-reduce-paranoia"
            eprintln ""
            exit 1
        fi
    }

    check /proc/sys/kernel/perf_event_paranoid "-1" "allow all perf events"
    check /proc/sys/kernel/kptr_restrict "0" "expose kernel symbols"

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
    #!/usr/bin/env bash
    set -euo pipefail

    # retry a command until it fails
    # set `N=10` to run across 10 processes, in parallel.
    function retry() {
        # Check for args
        [[ $# -eq 0 ]] && exit 1

        # Number of parallel processes
        N=${N:-1}

        # Spawns a child worker
        do_work() {
            while "$@"; do :; done
        }
        export -f do_work

        # Simplified handling for case N=1
        if [[ $N -eq 1 ]]; then
            do_work "$@"
        else
            # Use GNU parallel to run the workers in parallel, exiting early when
            # the first fails.
            seq "$N" | parallel --jobs "$N" --ungroup --halt now,done=1 do_work "$@"
        fi
    }

    nix build {{ drv }}
    retry nix build --rebuild --offline {{ drv }}

# `perf` profile the background `nix-daemon` process
perf-nix-daemon:
    #!/usr/bin/env bash
    set -euo pipefail

    just perf-check-not-paranoid
    nixd_pid="$(just nix-daemon-pid)"
    nix="$(which nix)"

    # --timestamp
    # --stat
    # --call-graph=lbr
    # --call-graph=dwarf
    # --cgroup=/system.slice/nix-daemon.service
    sudo perf record \
        --pid=$nixd_pid --inherit --freq=2000 -g --call-graph=dwarf \
        -- sleep 15

    sudo chown $USER:$USER perf.data
    chmod a+r perf.data

    perf script --fields +pid > perf.data.txt

# `samply` profile `nix $cmd`
samply-nix *cmd:
    #!/usr/bin/env bash
    set -euo pipefail

    # setup
    just perf-check-not-paranoid
    nix="$(which nix)"
    sample_rate=1999 # 997 # 97 # 3989
    samply="$(which samply)"

    # profile the cmd
    $(which samply) record \
        --rate $sample_rate \
        --cswitch-markers \
        --save-only \
        --output profile.nix.json.gz \
        -- $nix {{ cmd }}

    # make profile and nix output link user-owned
    sudo chown --no-dereference $USER:$USER profile.*.json.gz result*
    chmod a+r profile.*.json.gz

# `samply` profile the bg nix-daemon while also profiling `nix $cmd`
samply-nix-and-daemon *cmd:
    #!/usr/bin/env bash
    set -euo pipefail

    # setup
    just perf-check-not-paranoid
    nix="$(which nix)"
    nixd_pid="$(just nix-daemon-pid)"
    sample_rate=1999 # 997 # 97 # 3989
    samply="$(which samply)"

    # stops the nix-daemon profiler
    bg_profiler_pid=""
    stop_samply_nix_daemon() {
        if [[ ! -z "$bg_profiler_pid" ]]; then
            sudo kill -SIGINT $bg_profiler_pid
            wait $bg_profiler_pid
        fi
    }

    # make sure we always cleanup
    trap stop_samply_nix_daemon EXIT

    # start profiling the nix-daemon process in the background
    sudo $samply record \
        --pid $nixd_pid \
        --rate $sample_rate \
        --cswitch-markers \
        --save-only \
        --output profile.nix-daemon.json.gz \
        &
    bg_profiler_pid=$!

    # wait for bg profiler to warm up
    sleep 1s

    # profile the cmd
    sudo $(which samply) record \
        --rate $sample_rate \
        --cswitch-markers \
        --save-only \
        --output profile.nix.json.gz \
        -- $nix {{ cmd }}

    # stop the background profiler and clear the trap
    stop_samply_nix_daemon
    trap - EXIT

    # make profile and nix output link user-owned
    sudo chown --no-dereference $USER:$USER profile.*.json.gz result*
    chmod a+r profile.*.json.gz

# samply load profile in browser
samply-load file="profile.nix.json.gz":
    samply load {{ file }}
