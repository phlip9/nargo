{
  craneLib,
  nargoLib,
  pkgs,
}: let
  inherit (builtins) catAttrs attrValues;
in rec {
  examples = import ./examples {inherit craneLib nargoLib pkgs;};

  # Ensure all examples can run `generateCargoMetadata` successfully.
  genMetadataAllExamples = pkgs.symlinkJoin {
    name = "gen-metadata-all";
    paths = catAttrs "metadata" (attrValues examples);
  };

  jq-tests =
    pkgs.runCommandLocal "jq-tests" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      mkdir $out
      jq -n -L "${../lib/jq}" -f "${./jq/tests.jq}" > $out/tests.json
    '';
}
