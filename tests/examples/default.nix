{
  craneLib,
  nargoLib,
}: let
  mkExamplePkg = {
    src,
    name,
  }: let
    srcCleaned = craneLib.cleanCargoSource src;
  in rec {
    src = srcCleaned;
    cargoVendorDir = craneLib.vendorCargoDeps {src = srcCleaned;};
    metadata = nargoLib.generateCargoMetadata {
      inherit cargoVendorDir;
      src = srcCleaned;
    };
  };
in {
  hello-world-bin = mkExamplePkg {
    name = "hello-world-bin";
    src = ./hello-world-bin;
  };
}
