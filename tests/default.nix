{
  craneLib,
  nargoLib,
}: {
  examples = import ./examples {inherit craneLib nargoLib;};
}
