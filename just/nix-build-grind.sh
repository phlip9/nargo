#!/usr/bin/env bash
set -euo pipefail

# retry a command until it fails
# set `N=10` to run across 10 processes, in parallel.
retry() {
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

nix build "$@"
retry nix build --rebuild --offline "$@"
