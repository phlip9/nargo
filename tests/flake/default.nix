# Manually fetch our dev- and test-only flake `inputs`.
#
# Output:
#
# ```nix
# {
#   nixpkgs = { .. };
#   crane = { .. };
# }
# ```
let
  inherit (builtins) flakeRefToString fromJSON getFlake mapAttrs readFile removeAttrs;

  # Read ./flake.lock and fetch+build flake `inputs`
  # TODO(phlip9): needs rework if any of our dev inputs have deps.
  lockFile = fromJSON (readFile ./flake.lock);
  getFlakeInput = _name: input: getFlake (flakeRefToString input.locked);
  flakeInputs = removeAttrs lockFile.nodes ["root"];
in
  mapAttrs getFlakeInput flakeInputs
