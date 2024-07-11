{
  craneLib,
  inputs,
  nargoLib,
  pkgs,
}: let
  inherit (pkgs.lib) mapAttrs';
in rec {
  examples = import ./examples {inherit craneLib inputs nargoLib pkgs;};

  checks =
    mapAttrs' (name: value: {
      name = "${name}-metadata";
      value = value.metadata;
    })
    examples;
}
