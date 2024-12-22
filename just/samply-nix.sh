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
  -- $nix "$@"

# make profile and nix output link user-owned
sudo chown --no-dereference $USER:$USER profile.*.json.gz result*
chmod a+r profile.*.json.gz
