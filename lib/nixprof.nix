{
  python3Packages,
  fetchFromGitHub,
  moreutils,
}:
python3Packages.buildPythonApplication {
  name = "nixprof";

  src = fetchFromGitHub {
    owner = "Kha";
    repo = "nixprof";
    rev = "8a36221436d1a0f336ba8432dd8ffebbb82c3b29";
    hash = "sha256-8KH3mZZVNB9rf42jSsllsJcs06JVxzgYkvmGgbSkMlI=";
  };

  build-system = [
    python3Packages.setuptools
  ];

  dependencies = [
    python3Packages.networkx
    python3Packages.pydot
    python3Packages.click
    python3Packages.tabulate
  ];

  makeWrapperArgs = ["--prefix PATH : ${moreutils}/bin"];
}
