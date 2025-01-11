let
  # Build the flake.nix `outputs`. This simplified approach only works while
  # we have zero inputs.
  outputs = (import ./flake.nix).outputs {self = outputs;};

  # add `<output>.currentSystem = <output>.${system};` to each flake output.
  # this makes it slightly more convenient to use from CLI.
  outputsWithCurrentSystem =
    builtins.mapAttrs (
      _name: value:
        if value ? ${builtins.currentSystem}
        then (value // {currentSystem = value.${builtins.currentSystem};})
        else value
    )
    outputs;
in
  outputsWithCurrentSystem
