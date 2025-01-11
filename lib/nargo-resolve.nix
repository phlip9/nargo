# cargo build -p nargo-resolve --bin nargo-resolve
{
  buildPackage,
  pkgs,
}:
buildPackage {
  workspacePath = ../.;
  pkgsCross = pkgs;
  packages = ["nargo-resolve"];
  bins = ["nargo-resolve"];
}
