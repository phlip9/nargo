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

  checks = _mkTestGroup "" {
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
  };

  # ignore broken tests
  ignored = {
    # TODO(phlip9): openssl-sys build.rs
    examples-crane-codesign-build = null;
    examples-gitoxide-build = null;
    examples-nushell-build = null;

    # TODO(phlip9): openssl linking?
    examples-hickory-dns-build = null;

    # TODO(phlip9): jemalloc-sys build.rs
    examples-fd-build = null;

    # TODO(phlip9): grpcio-sys build.rs
    examples-crane-grpcio-test-build = null;

    # TODO(phlip9): linked panic runtime `panic_unwind` not compiled with
    # crate's panic strategy `abort`
    examples-pkg-targets-build = null;

    # TODO(phlip9): support dep with Cargo.toml lib.name override
    # (ex: crate `new_debug_unreachable` uses `lib.name = "debug_unreachable"`)
    examples-nocargo-crate-names-build = null;
    examples-nocargo-custom-lib-name-build = null;
    examples-starlark-rust-build = null;

    # TODO(phlip9): build.rs `CARGO_MANIFEST_LINKS` is unset
    examples-wasmtime-build = null;

    # TODO(phlip9): nargo-rustc handle multiple output libs
    examples-crane-with-libs-build = null;

    # TODO(phlip9): top-level proc-macro feature resolution mismatch
    examples-crane-proc-macro-checkResolveFeatures = null;

    # TODO(phlip9): build.rs trying to write to `$src/target` dir
    examples-crane-with-build-script-build = null;
    examples-crane-with-build-script-custom-build = null;
    examples-rage-build = null;

    # TODO(phlip9): build.rs cargo::rustc-link-{lib,search} propagation
    examples-nocargo-libz-dynamic-build = null;

    # TODO(phlip9): build.rs `DEP_Z_INCLUDE` env missing
    examples-nocargo-libz-static-build = null;

    # TODO(phlip9): build.rs cmake + bindgen
    examples-crane-highs-sys-test-build = null;
  };
  checksFlat = builtins.listToAttrs checks._tests;

  # work around garnix's max 100-top-level-packages limit and 30 minute build
  # timeout by sharding our tests into chunks.
  garnix-check-shards = let
    numShards = 20;
    tests = checks._tests;
    numTests = builtins.length tests;
    testsPerShard = builtins.div numTests numShards;

    mkShard = shardIdx: let
      idxStart = testsPerShard * shardIdx;
      idxEnd =
        if shardIdx == numShards - 1
        then numTests
        else testsPerShard * (shardIdx + 1);
      shardId =
        if shardIdx < 10
        then "0${builtins.toString shardIdx}"
        else builtins.toString shardIdx;
      shardName = "garnix-check-shard-${shardId}";
      shardTests = builtins.genList (idx: builtins.elemAt tests (idxStart + idx)) (idxEnd - idxStart);
    in {
      name = shardName;
      value = pkgs.linkFarm shardName (builtins.listToAttrs shardTests);
    };
  in
    builtins.listToAttrs (builtins.genList mkShard numShards);

  _mkTestGroup = prefix: value:
  # case: derivation
    if lib.isDerivation value
    then
      (value
        // {
          _tests =
            if ignored ? ${prefix}
            then []
            else [
              {
                name = prefix;
                value = value;
              }
            ];
        })
    # case: assertion
    else if lib.isType "assertion" value
    then _mkTestGroup prefix (value.fn prefix)
    # case: eval test fn
    else if lib.isFunction value
    then _mkTestGroup prefix (value _testFnArgs)
    # case: attrset test group
    else if lib.isAttrs value
    then let
      subTestGroups =
        builtins.mapAttrs
        (
          name:
            _mkTestGroup
            (
              if builtins.stringLength prefix != 0
              then "${prefix}-${name}"
              else name
            )
        )
        value;
      testGroup = builtins.concatLists (builtins.map
        (subTestGroup: subTestGroup._tests)
        (builtins.attrValues subTestGroups));
      testGroupDrv = pkgs.linkFarm prefix (builtins.listToAttrs testGroup);
    in
      subTestGroups
      // {
        # group derivation that builds all tests in the test group
        type = "derivation";
        outputs = ["out"];
        inherit (testGroupDrv) out outPath outputName drvPath name system;
        # subtests
        _tests = testGroup;
      }
    else throw "Unexpected test type: ${prefix}: ${builtins.typeOf value}";

  _testFnArgs = {
    assertEq = actual: expect: {
      _type = "assertion";
      fn = name:
        if builtins.toJSON actual == builtins.toJSON expect
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
            actual = builtins.toJSON actual;
            expect = builtins.toJSON expect;
          } ''
            if [[ ''${#actual} < 32 && ''${#expect} < 32 ]]; then
              echo "actual: $actual"
              echo "expect: $expect"
            else
              echo "actual:"
              jq . <<<"$actual"
              echo
              echo "expect:"
              jq . <<<"$expect"
              echo
              echo "diff:"
              diff -y <(jq . <<<"$actual") <(jq . <<<"$expect")
              exit 1
            fi
          '';
    };
  };
}
