{
  craneLib,
  nargoLib,
  pkgs,
}: let
  inherit (builtins) attrNames map;
in rec {
  examples = import ./examples {inherit craneLib nargoLib pkgs;};

  # Ensure all examples can run `generateCargoMetadata` successfully.
  genMetadataAllExamples = pkgs.linkFarm "gen-metadata-all" (
    map (name: {
      name = name;
      path = examples.${name}.metadata;
    }) (attrNames examples)
  );
}
