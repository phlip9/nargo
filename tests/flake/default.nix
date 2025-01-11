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
#
# TODO(phlip9): needs rework if any of our dev inputs have deps.
let
  inherit (builtins) fetchTarball fromJSON mapAttrs readFile removeAttrs;

  # Read ./flake.lock
  lockFile = fromJSON (readFile ./flake.lock);

  lockedInputs = removeAttrs lockFile.nodes ["root"];

  fetchLockedFlake = locked:
    if locked.type != "github"
    then throw "nargo: error: unsupported flake input type: ${locked.type}"
    else
      fetchTarball {
        url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
        sha256 = locked.narHash;
      };

  getLockedFlake = _name: input: let
    src = fetchLockedFlake input.locked;
    flake = import (src + "/flake.nix");
    outputs = flake.outputs {self = outputs;};
  in
    outputs // {outPath = src;};
in
  mapAttrs getLockedFlake lockedInputs
