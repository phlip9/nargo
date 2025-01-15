{
  inputsTest,
  lib,
  nargoLib,
  pkgs,
}: rec {
  craneLib = inputsTest.crane.mkLib pkgs;

  # An extension on `nargoLib` with dev-/test-only entries.
  nargoTestLib = import ./lib {inherit craneLib lib pkgs nargoLib;};

  examples = import ./examples {inherit craneLib inputsTest lib nargoLib nargoTestLib pkgs;};

  resolve = import ./resolve.nix {inherit nargoLib;};

  targetCfg = import ./targetCfg.nix {inherit lib nargoLib;};

  packages = {
    nargo-metadata = nargoLib.nargo-metadata;
    nargo-resolve = nargoLib.nargo-resolve;
    nargo-rustc = nargoLib.nargo-rustc;
  };

  checksAll = builtins.listToAttrs (lib.flatten (_flattenTests "tests" {
    targetCfg = targetCfg;
    examples = builtins.mapAttrs (_: value:
      builtins.intersectAttrs {
        metadataDrv = null;
        checkResolveFeatures = null;
        build = null;
      }
      value)
    examples;
    packages = packages;
  }));

  # ignore broken tests
  ignored = [
    # TODO(phlip9): openssl-sys build.rs
    "tests-examples-crane-codesign-build"
    "tests-examples-gitoxide-build"
    "tests-examples-nushell-build"

    # TODO(phlip9): openssl linking?
    "tests-examples-hickory-dns-build"

    # TODO(phlip9): jemalloc-sys build.rs
    "tests-examples-fd-build"

    # TODO(phlip9): grpcio-sys build.rs
    "tests-examples-crane-grpcio-test-build"

    # TODO(phlip9): linked panic runtime `panic_unwind` not compiled with
    # crate's panic strategy `abort`
    "tests-examples-pkg-targets-build"

    # TODO(phlip9): support dep with Cargo.toml lib.name override
    # (ex: crate `new_debug_unreachable` uses `lib.name = "debug_unreachable"`)
    "tests-examples-nocargo-crate-names-build"
    "tests-examples-nocargo-custom-lib-name-build"
    "tests-examples-starlark-rust-build"

    # TODO(phlip9): build.rs `CARGO_MANIFEST_LINKS` is unset
    "tests-examples-wasmtime-build"

    # TODO(phlip9): examples with custom target selection
    "tests-examples-crane-dependencyBuildScriptPerms-build"
    "tests-examples-crane-simple-only-tests-build"
    "tests-examples-crane-with-libs-build"
    "tests-examples-crane-with-libs-some-dep-build"
    "tests-examples-crane-workspace-git-build"
    "tests-examples-nocargo-workspace-proc-macro-lto-build"
    "tests-examples-rand-build"

    # TODO(phlip9): build.rs trying to write to `$src/target` dir
    "tests-examples-crane-with-build-script-build"
    "tests-examples-crane-with-build-script-custom-build"
    "tests-examples-rage-build"

    # TODO(phlip9): build.rs cargo::rustc-link-{lib,search} propagation
    "tests-examples-nocargo-libz-dynamic-build"

    # TODO(phlip9): build.rs `DEP_Z_INCLUDE` env missing
    "tests-examples-nocargo-libz-static-build"

    # TODO(phlip9): build.rs cmake + bindgen
    "tests-examples-crane-highs-sys-test-build"
  ];
  checks = builtins.removeAttrs checksAll ignored;

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
