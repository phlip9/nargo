{
  lib,
  nargoLib,
}: let
  inherit (nargoLib) targetCfg;
in {
  cfg-parser-tests = {assertEq, ...}: let
    shouldParse = cfg: expect:
      assertEq (builtins.tryEval (targetCfg.parseTargetCfgExpr cfg)) {
        success = true;
        value = expect;
      };
    shouldNotParse = cfg:
      assertEq (builtins.tryEval (targetCfg.parseTargetCfgExpr cfg)) {
        success = false;
        value = false;
      };
  in {
    simple-target1 =
      shouldParse "thumbv8m.base-none-eabi"
      {
        key = "target";
        value = "thumbv8m.base-none-eabi";
      };
    simple-target2 =
      shouldParse "aarch64-unknown-linux-gnu"
      {
        key = "target";
        value = "aarch64-unknown-linux-gnu";
      };

    simple1 = shouldParse "cfg(atom)" {key = "atom";};
    simple2 = shouldParse ''cfg(k = "v")'' {
      key = "k";
      value = "v";
    };
    complex =
      shouldParse ''cfg( all ( not ( a , ) , b , all ( ) , any ( c , d = "e" ) , ) )''
      {
        fn = "all";
        values = [
          {
            fn = "not";
            values = [{key = "a";}];
          }
          {key = "b";}
          {
            fn = "all";
            values = [];
          }
          {
            fn = "any";
            values = [
              {key = "c";}
              {
                key = "d";
                value = "e";
              }
            ];
          }
        ];
      };

    invalid-cfg1 = shouldNotParse "cfg (a)";
    invalid-cfg2 = shouldNotParse "cfg()";
    invalid-cfg3 = shouldNotParse "cfg(a,b)";
    invalid-not1 = shouldNotParse "cfg(not(a,b))";
    invalid-not2 = shouldNotParse "cfg(not())";
    invalid-comma1 = shouldNotParse "cfg(all(,))";
    invalid-comma2 = shouldNotParse "cfg(all(a,,b))";
    invalid-comma3 = shouldNotParse "cfg(all(a,b,,))";
    invalid-comma4 = shouldNotParse "cfg(all(a b))";
    invalid-comma5 = shouldNotParse "cfg(all(any() any()))";
    invalid-paren1 = shouldNotParse "cfg(all(a)))";
    invalid-paren2 = shouldNotParse "cfg(all(a)";
  };

  cfg-eval-tests = {assertEq, ...}: let
    cfgs = [
      {key = "foo";}
      {key = "bar";}
      {
        key = "feature";
        value = "foo";
      }
      {
        key = "feature";
        value = "bar";
      }
    ];
    test = cfg: expect: assertEq (targetCfg.evalTargetCfgStr cfgs cfg) expect;
  in {
    simple1 = test ''cfg(foo)'' true;
    simple2 = test ''cfg(baz)'' false;
    simple3 = test ''cfg(feature = "foo")'' true;
    simple4 = test ''cfg(foo = "")'' false;
    simple5 = test ''cfg(wtf = "foo")'' false;

    all1 = test ''cfg(all())'' true;
    all2 = test ''cfg(all(foo))'' true;
    all3 = test ''cfg(all(baz))'' false;
    all4 = test ''cfg(all(foo,bar))'' true;
    all5 = test ''cfg(all(foo,bar,baz))'' false;
    all6 = test ''cfg(all(foo,baz,bar))'' false;
    all7 = test ''cfg(all(baz,foo))'' false;
    all8 = test ''cfg(all(baz,feature="foo"))'' false;
    all9 = test ''cfg(all(baz,feature="wtf"))'' false;
    all10 = test ''cfg(all(foo,feature="foo"))'' true;

    any1 = test ''cfg(any())'' false;
    any2 = test ''cfg(any(foo))'' true;
    any3 = test ''cfg(any(baz))'' false;
    any4 = test ''cfg(any(foo,bar))'' true;
    any5 = test ''cfg(any(foo,bar,baz))'' true;
    any6 = test ''cfg(any(foo,baz,bar))'' true;
    any7 = test ''cfg(any(baz,foo))'' true;
    any8 = test ''cfg(any(baz,feature="foo"))'' true;
    any9 = test ''cfg(any(baz,feature="wtf"))'' false;
    any10 = test ''cfg(any(foo,feature="wtf"))'' true;

    not1 = test ''cfg(not(foo))'' false;
    not2 = test ''cfg(not(wtf))'' true;
  };

  cfg-eval-smoketests = {assertEq, ...}: let
    targets = ["x86_64-unknown-linux-gnu" "aarch64-apple-darwin"];
    cfgs = builtins.listToAttrs (map (target: {
        name = target;
        value = targetCfg.platformToCfgs (lib.systems.elaborate target);
      })
      targets);
    test = target: cfg: expect: assertEq (targetCfg.evalTargetCfgStr cfgs.${target} cfg) expect;
  in {
    windows1 = test "x86_64-unknown-linux-gnu" "cfg(windows)" false;
    windows2 = test "aarch64-apple-darwin" "cfg(windows)" false;

    notWindows1 = test "x86_64-unknown-linux-gnu" "cfg(not(windows))" true;
    notWindows2 = test "aarch64-apple-darwin" "cfg(not(windows))" true;

    unix1 = test "x86_64-unknown-linux-gnu" "cfg(unix)" true;
    unix2 = test "aarch64-apple-darwin" "cfg(unix)" true;

    notUnix1 = test "x86_64-unknown-linux-gnu" "cfg(not(unix))" false;
    notUnix2 = test "aarch64-apple-darwin" "cfg(not(unix))" false;

    targetA1 = test "x86_64-unknown-linux-gnu" "x86_64-unknown-linux-gnu" true;
    targetA2 = test "x86_64-unknown-linux-gnu" "x86_64-unknown-linux-musl" false;
    targetA3 = test "x86_64-unknown-linux-gnu" "aarch64-apple-darwin" false;

    targetB1 = test "aarch64-apple-darwin" "x86_64-unknown-linux-gnu" false;
    targetB2 = test "aarch64-apple-darwin" "x86_64-unknown-linux-musl" false;
    targetB3 = test "aarch64-apple-darwin" "aarch64-apple-darwin" true;
  };

  platform-cfg-tests = {assertEq, ...}: let
    inherit (lib.systems) elaborate;
    test = config: expect: let
      cfgs = targetCfg.platformToCfgs (elaborate config);
      strs =
        map (
          {
            key,
            value ? null,
          }:
            if value != null
            then "${key}=\"${value}\"\n"
            else "${key}\n"
        )
        cfgs;
      got = builtins.concatStringsSep "" (builtins.sort (a: b: a < b) strs);
    in
      assertEq got expect;
  in {
    attrs-x86_64-linux = assertEq (targetCfg.platformToCfgAttrs (elaborate "x86_64-unknown-linux-gnu")) {
      target = "x86_64-unknown-linux-gnu";
      target_arch = "x86_64";
      target_endian = "little";
      target_env = "gnu";
      target_family = "unix";
      target_feature = ["fxsr" "sse" "sse2"];
      target_has_atomic = ["16" "32" "64" "8" "ptr"];
      target_os = "linux";
      target_pointer_width = "64";
      target_vendor = "unknown";
      unix = true;
    };

    cfg-x86_64-linux = test "x86_64-unknown-linux-gnu" ''
      target="x86_64-unknown-linux-gnu"
      target_arch="x86_64"
      target_endian="little"
      target_env="gnu"
      target_family="unix"
      target_feature="fxsr"
      target_feature="sse"
      target_feature="sse2"
      target_has_atomic="16"
      target_has_atomic="32"
      target_has_atomic="64"
      target_has_atomic="8"
      target_has_atomic="ptr"
      target_os="linux"
      target_pointer_width="64"
      target_vendor="unknown"
      unix
    '';

    cfg-aarch64-linux = test "aarch64-unknown-linux-gnu" ''
      target="aarch64-unknown-linux-gnu"
      target_arch="aarch64"
      target_endian="little"
      target_env="gnu"
      target_family="unix"
      target_os="linux"
      target_pointer_width="64"
      target_vendor="unknown"
      unix
    '';
  };
}
