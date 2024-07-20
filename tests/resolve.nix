{nargoLib}: {
  dumpWorkspace = let
    metadata = builtins.readFile (builtins.fromJSON ../Cargo.metadata.json);
    buildTarget = "x86_64-unknown-linux-gnu";
    hostTarget = "x86_64-unknown-linux-gnu";
  in
    nargoLib.resolve.resolveFeatures {inherit metadata buildTarget hostTarget;};
}
