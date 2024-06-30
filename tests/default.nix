{
  craneLib,
  nargoLib,
  pkgs,
}: {
  examples = import ./examples {inherit craneLib nargoLib pkgs;};
}
