{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, ... }@inputs:
    let
      lib = inputs.nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = builder: lib.genAttrs systems builder;
      systemPkgs = eachSystem (system: inputs.nixpkgs.legacyPackages.${system});
    in {
        lib = {
          crater = eachSystem (system: import ./tests/crater {
            inputs = inputs;
            pkgs = systemPkgs.${system};
          });
        };
    };
}
