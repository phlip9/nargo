{
  # For external usage, nargo's only dependency is the `nixpkgs` instance users
  # pass in to `nargo.lib.mkLib`. Since nix flakes don't have a notion of
  # dev-dependencies, we'll manually manage dev- and test-only deps in
  # `./tests/flake/flake.nix`.
  inputs = {};

  outputs = {self}: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    genAttrs = names: builder:
      builtins.listToAttrs (builtins.map (name: {
          name = name;
          value = builder name;
        })
        names);
    eachSystem = builder: genAttrs systems builder;

    # Manually fetch our dev- and test-only flake `inputs`.
    inputsTest = import ./tests/flake;

    systemPkgs = eachSystem (system: inputsTest.nixpkgs.legacyPackages.${system});
    eachSystemPkgs = builder: eachSystem (system: builder systemPkgs.${system});

    systemNargoLib = eachSystemPkgs (pkgs: self.lib.mkLib pkgs);
    systemNargoTestLib = eachSystem (system: self.tests.${system}.nargoTestLib);
  in {
    #
    # Public
    #

    # Example usage:
    #
    # ```nix
    # pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
    # nargoLib = nargo.lib.mkLib pkgs;
    # myCrate = nargoLib.buildPackage { .. };
    # ```
    lib = {
      mkLib = pkgs:
        import ./lib {
          lib = pkgs.lib;
          pkgs = pkgs;
        };
    };

    #
    # Private
    #

    packages = eachSystem (system: let
      nargoLib = systemNargoLib.${system};
    in {
      # smuggle this in via `packages` to get garnix to build it
      garnix-all-checks = self.tests.${system}.garnix-all-checks;

      nargo-metadata = nargoLib.nargo-metadata;
      nargo-resolve = nargoLib.nargo-resolve;
      nargo-rustc = nargoLib.nargo-rustc;
    });

    devShells = eachSystem (
      system: let
        mkMinShell = nargoTestLib.mkMinShell;
        nargoTestLib = systemNargoTestLib.${system};
        pkgs = systemPkgs.${system};
      in {
        bash-lint = mkMinShell {
          name = "bash-lint";
          packages = [pkgs.fd pkgs.shellcheck pkgs.shfmt];
        };

        nix-test = mkMinShell {
          name = "nix-test";
          packages = [pkgs.nix-fast-build];
        };
      }
    );

    tests = eachSystem (system:
      import ./tests {
        lib = inputsTest.nixpkgs.lib;
        inputsTest = inputsTest;
        nargoLib = systemNargoLib.${system};
        pkgs = systemPkgs.${system};
      });

    checks = eachSystem (system: self.tests.${system}.checks);

    formatter = eachSystemPkgs (pkgs: pkgs.alejandra);

    _dbg = {
      inputsDev = inputsTest;
      systemNargoLib = systemNargoLib;
      systemNargoTestLib = systemNargoTestLib;
      systemPkgs = systemPkgs;
    };
  };
}
