# Vendored from nocargo:
# <https://github.com/oxalica/nocargo/blob/7fdb03e1be21411764271f2ec85187870f0a9428/lib/target-cfg.nix>
#
# TODO(phlip9): copied this over to unblock, but needs rework
{lib, ...}: let
  inherit
    (lib)
    length
    elem
    elemAt
    any
    all
    flatten
    isList
    optionalAttrs
    mapAttrsToList
    ;
in rec {
  # https://doc.rust-lang.org/reference/conditional-compilation.html#target_arch
  platformToTargetArch = platform:
    if platform.isAarch32
    then "arm"
    else platform.parsed.cpu.name;

  # https://doc.rust-lang.org/reference/conditional-compilation.html#target_os
  platformToTargetOs = platform:
    if platform.isDarwin
    then "macos"
    else platform.parsed.kernel.name;

  # https://github.com/rust-lang/rust/blob/9bc8c42bb2f19e745a63f3445f1ac248fb015e53/compiler/rustc_session/src/config.rs#L835
  # https://doc.rust-lang.org/reference/conditional-compilation.html
  platformToCfgAttrs = platform:
    {
      # Arch info.
      # https://github.com/NixOS/nixpkgs/blob/c63d4270feed5eb6c578fe2d9398d3f6f2f96811/pkgs/build-support/rust/build-rust-crate/configure-crate.nix#L126
      target_arch = platformToTargetArch platform;
      target_endian =
        if platform.isLittleEndian
        then "little"
        else if platform.isBigEndian
        then "big"
        else throw "Unknow target_endian for ${platform.config}";
      target_env =
        if platform.isNone
        then ""
        else if platform.libc == "glibc"
        then "gnu"
        else if platform.isMusl
        then "musl"
        else if platform.isDarwin
        then "" # Empty
        else lib.trace platform (throw "Unknow target_env for ${platform.config}");
      target_family =
        if platform.isUnix
        then "unix"
        else if platform.isWindows
        then "windows"
        else null;
      target_os = platformToTargetOs platform;
      target_pointer_width = toString platform.parsed.cpu.bits;
      target_vendor = platform.parsed.vendor.name;
    }
    // optionalAttrs platform.isx86 {
      # These features are assume to be available.
      target_feature = ["fxsr" "sse" "sse2"];
      # TODO(phlip9): be systematic about this
      target_has_atomic = ["16" "32" "64" "8" "ptr"];
    }
    // optionalAttrs platform.isUnix {
      unix = true;
    }
    // optionalAttrs platform.isWindows {
      windows = true;
    };

  platformToCfgs = platform:
    flatten (
      mapAttrsToList (
        key: value:
          if value == true
          then {inherit key;}
          else if isList value
          then map (value: {inherit key value;}) value
          else {inherit key value;}
      ) (platformToCfgAttrs platform)
    );

  # cfgs: [
  #   { key = "atom1"; }
  #   { key = "atom2"; }
  #   { key = "feature"; value = "foo"; }
  #   { key = "feature"; value = "bar"; }
  # ]
  evalTargetCfgStr = cfgs: s:
    evalCfgExpr cfgs (parseTargetCfgExpr s);

  # Cargo's parse is stricter than rustc's.
  # - Must starts with `cfg(` and ends with `)`. No spaces are allowed before and after.
  # - Identifiers must follows /[A-Za-z_][A-Za-z_0-9]*/.
  # - Raw identifiers, raw strings, escapes in strings are not allowed.
  #
  # The target can also be a simple target name like `aarch64-unknown-linux-gnu`, which will be parsed
  # as if it's `cfg(target = "...")`.
  #
  # https://github.com/rust-lang/cargo/blob/dcc95871605785c2c1f2279a25c6d3740301c468/crates/cargo-platform/src/cfg.rs
  parseTargetCfgExpr = cfg: let
    fail = reason: throw "${reason}, when parsing `${cfg}";

    go = {
      fn,
      values,
      afterComma,
      prev,
    } @ stack: s: let
      m =
        builtins.match
        ''((all|any|not) *\( *|(\)) *|(,) *|([A-Za-z_][A-Za-z_0-9]*) *(= *"([^"]*)" *)?)(.*)''
        s;
      mFn = elemAt m 1;
      mClose = elemAt m 2;
      mComma = elemAt m 3;
      mIdent = elemAt m 4;
      mString = elemAt m 6;
      mRest = elemAt m 7;
    in
      if s == ""
      then stack
      else if m == null
      then fail "No parse `${s}`"
      # else if builtins.trace ([ stack m ]) (mFn != null) then
      else if mFn != null
      then
        if !afterComma
        then fail "Missing comma before `${mFn}` at `${s}"
        else
          go {
            fn = mFn;
            values = [];
            afterComma = true;
            prev = stack;
          }
          mRest
      else if mClose != null
      then
        if prev == null
        then fail "Unexpected `)` at `${s}`"
        else if fn == "not" && length values == 0
        then fail "`not` must have exact one argument, got 0"
        else if prev.fn == "not" && length prev.values != 0
        then fail "`not` must have exact one argument, got at least 2"
        else
          go (prev
            // {
              values = prev.values ++ [{inherit (stack) fn values;}];
              afterComma = false;
            })
          mRest
      else if mComma != null
      then
        if afterComma
        then fail "Unexpected `,` at `${s}`"
        else go (stack // {afterComma = true;}) mRest
      else if !afterComma
      then fail "Missing comma before identifier `${mIdent}` at `${s}"
      else if fn == "not" && length values != 0
      then fail "`not` must have exact one argument, got at least 2"
      else let
        kv =
          if mString != null
          then {
            key = mIdent;
            value = mString;
          }
          else {key = mIdent;};
      in
        go (stack
          // {
            afterComma = false;
            values = values ++ [kv];
          })
        mRest;

    mSimpleTarget = builtins.match "[A-Za-z_0-9_.-]+" cfg;

    mCfg = builtins.match ''cfg\( *(.*)\)'' cfg;
    mCfgInner = elemAt mCfg 0;
    ret =
      go {
        fn = "cfg";
        values = [];
        afterComma = true;
        prev = null;
      }
      mCfgInner;
  in
    if mSimpleTarget != null
    then {
      key = "target";
      value = cfg;
    }
    else if mCfg == null
    then fail "Cfg expr must be a simple target string, or start with `cfg(` and end with `)`"
    else if ret.prev != null
    then fail "Missing `)`"
    else if length ret.values != 1
    then fail "`cfg` must have exact one argument, got ${toString (length ret.values)}"
    else elemAt ret.values 0;

  evalCfgExpr = cfgs: tree:
    if !(tree ? fn)
    then elem tree cfgs
    else if tree.fn == "all"
    then all (evalCfgExpr cfgs) tree.values
    else if tree.fn == "any"
    then any (evalCfgExpr cfgs) tree.values
    else !evalCfgExpr cfgs (elemAt tree.values 0);
}
