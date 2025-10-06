# Easily debug workspace nargo feature resolution.
{nargoLib}: let
  metadata = builtins.fromJSON (builtins.readFile ../Cargo.metadata.json);
  resolveFeatures = nargoLib.resolve.resolveFeatures;
  buildTargets = [
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
  ];
  hostTargets = [
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "wasm32-wasi"
  ];
in
  builtins.listToAttrs (builtins.map (buildTarget: {
      name = buildTarget;
      value = builtins.listToAttrs (builtins.map (hostTarget: {
          name = hostTarget;
          value = resolveFeatures {
            metadata = metadata;
            buildTarget = buildTarget;
            hostTarget = hostTarget;
            # rootPkgIds = ["nargo-metadata"];
          };
        })
        hostTargets);
    })
    buildTargets)
