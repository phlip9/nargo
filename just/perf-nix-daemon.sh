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
