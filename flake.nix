{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...} @ inputs: let
    lib = inputs.nixpkgs.lib;

    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    eachSystem = builder: lib.genAttrs systems builder;

    systemPkgs = eachSystem (system: inputs.nixpkgs.legacyPackages.${system});
    eachSystemPkgs = builder: eachSystem (system: builder systemPkgs.${system});

    systemCraneLib = eachSystemPkgs (pkgs: inputs.crane.mkLib pkgs);
    systemNargoLib = eachSystemPkgs (pkgs: self.lib.mkLib pkgs);
  in {
    lib = {
      mkLib = pkgs:
        import ./lib {
          lib = inputs.nixpkgs.lib;
          pkgs = pkgs;
          craneLib = systemCraneLib.${pkgs.system};
        };

      nargo = systemNargoLib;
    };

    packages = eachSystem (system: {
      nargo-metadata = systemNargoLib.${system}.nargo-metadata;
    });

    tests = eachSystem (system:
      import ./tests {
        craneLib = systemCraneLib.${system};
        inputs = inputs;
        nargoLib = systemNargoLib.${system};
        pkgs = systemPkgs.${system};
      });

    checks = eachSystem (system: self.tests.${system}.checks);
  };
}
