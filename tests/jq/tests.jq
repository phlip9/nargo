import "lib" as lib;

def assert:
    if . == false then error("assertion failed") else . end
    ;

def testInSemverRange:
    .
    | [
        ["1.2.3", "*", true],
        ["1.2.3", "^1", true],
        ["1.2.3", "^1.2", true],
        ["1.2.3", "^1.2.0", true],
        ["1.2.3", "^1.2.3", true],

        ["1.2.3", "^0", false],
        ["1.2.3", "^0.5", false],
        ["1.2.3", "^1.3", false],
        ["1.2.3", "^1.2.4", false],
        ["1.2.3", "^2", false]
      ]
    | map(
        . as [$version, $versionReq, $expected]
        | lib::inSemverRange($version; $versionReq)
        | if . != $expected then
            "error: inSemverRange('\($version)'; '\($versionReq)') != \($expected)"
          else true end
      )
    ;

{
    testInSemverRange: testInSemverRange,
}
