{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
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

    packages = eachSystem (system: let
      nargoLib = systemNargoLib.${system};
    in {
      nargo-metadata = nargoLib.nargo-metadata;
      nargo-resolve = nargoLib.nargo-resolve;
      nargo-rustc = nargoLib.nargo-rustc;

      nixprof = nargoLib.nixprof;
    });

    devShells = eachSystem (
      system: let
        nargoLib = systemNargoLib.${system};
        pkgs = systemPkgs.${system};
        mkMinShell = nargoLib.mkMinShell;
      in {
        bash-lint = mkMinShell {
          name = "bash-lint";
          packages = [pkgs.fd pkgs.shellcheck pkgs.shfmt];
        };
      }
    );

    tests = eachSystem (system:
      import ./tests {
        lib = inputs.nixpkgs.lib;
        craneLib = systemCraneLib.${system};
        inputs = inputs;
        nargoLib = systemNargoLib.${system};
        pkgs = systemPkgs.${system};
      });

    checks = eachSystem (system: self.tests.${system}.checks);

    formatter = eachSystemPkgs (pkgs: pkgs.alejandra);

    _dbg = {
      systemPkgs = systemPkgs;
      systemNargoLib = systemNargoLib;
    };
  };
}
