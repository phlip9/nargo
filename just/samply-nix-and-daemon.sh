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
  if [[ -n $bg_profiler_pid ]]; then
    sudo kill -SIGINT $bg_profiler_pid
    wait $bg_profiler_pid
  fi
}

# make sure we always cleanup
trap stop_samply_nix_daemon EXIT

# start profiling the nix-daemon process in the background
sudo "$samply" record \
  --pid "$nixd_pid" \
  --rate $sample_rate \
  --cswitch-markers \
  --save-only \
  --output profile.nix-daemon.json.gz \
  &
bg_profiler_pid=$!

# wait for bg profiler to warm up
sleep 1s

# profile the cmd
sudo "$samply" record \
  --rate $sample_rate \
  --cswitch-markers \
  --save-only \
  --output profile.nix.json.gz \
  -- "$nix" "$@"

# stop the background profiler and clear the trap
stop_samply_nix_daemon
trap - EXIT

# make profile and nix output link user-owned
sudo chown --no-dereference "$USER:$USER" profile.*.json.gz result*
chmod a+r profile.*.json.gz
