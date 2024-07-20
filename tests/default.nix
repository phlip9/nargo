{
  craneLib,
  inputs,
  nargoLib,
  pkgs,
}: let
  inherit (pkgs.lib) mapAttrs';
in rec {
  examples = import ./examples {inherit craneLib inputs nargoLib pkgs;};

  resolve = import ./resolve.nix {inherit nargoLib;};

  checks =
    mapAttrs' (name: value: {
      name = "${name}-metadata";
      value = value.metadata;
    })
    examples;
}
