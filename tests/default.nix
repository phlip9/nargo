{
  craneLib,
  inputs,
  nargoLib,
  pkgs,
  lib,
}: rec {
  examples = import ./examples {inherit craneLib inputs nargoLib pkgs;};

  resolve = import ./resolve.nix {inherit nargoLib;};

  targetCfg = import ./targetCfg.nix {inherit lib nargoLib;};

  packages = {
    nargo-metadata = nargoLib.nargo-metadata;
    nargo-resolve = nargoLib.nargo-resolve;
    nargo-rustc = nargoLib.nargo-rustc;
  };

  checks = builtins.listToAttrs (lib.flatten (_flattenTests "tests" {
    targetCfg = targetCfg;
    examples = builtins.mapAttrs (_: value:
      builtins.intersectAttrs {
        metadataDrv = null;
        checkResolveFeatures = null;
      }
      value)
    examples;
    packages = packages;
  }));

  # circumvent garnix's max 100-top-level-packages limit by making a giant
  # symlink join over all checks, so they only count as one "package".
  garnix-all-checks = pkgs.linkFarm "garnix-all-checks" checks;

  _flattenTests = prefix: v:
    if lib.isDerivation v
    then {
      name = prefix;
      value = v;
    }
    else if lib.isType "assertion" v
    then {
      name = prefix;
      value = v.fn prefix;
    }
    else if lib.isFunction v
    then _flattenTests prefix (v _testFnArgs)
    else if lib.isAttrs v
    then lib.mapAttrsToList (name: _flattenTests "${prefix}-${name}") v
    else throw "Unexpect test type: ${builtins.typeOf v}";

  _testFnArgs = {
    assertEq = got: expect: {
      _type = "assertion";
      fn = name:
        if builtins.toJSON got == builtins.toJSON expect
        then
          derivation {
            name = "ok";
            system = pkgs.system;
            builder = "/bin/sh";
            args = ["-c" ": >$out"];
          }
        else
          pkgs.runCommand "${name}-assert-eq-fail" {
            nativeBuildInputs = [pkgs.jq];
            got = builtins.toJSON got;
            expect = builtins.toJSON expect;
          } ''
            if [[ ''${#got} < 32 && ''${#expect} < 32 ]]; then
              echo "got:    $got"
              echo "expect: $expect"
            else
              echo "got:"
              jq . <<<"$got"
              echo
              echo "expect:"
              jq . <<<"$expect"
              echo
              echo "diff:"
              diff -y <(jq . <<<"$got") <(jq . <<<"$expect")
              exit 1
            fi
          '';
    };
  };
}
