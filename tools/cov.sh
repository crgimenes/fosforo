#!/bin/sh
# Line coverage of the C core and the Swift libraries, from the same test
# binaries the gate runs (ASan/UBSan kept), with LLVM's source-based
# coverage: build/cov/c.txt and build/cov/swift.txt, per file, and the
# totals on stdout. The apps (fosforo, fosforo-ios) have no tests and are
# not listed. Needs the sibling checkouts like make test does.
# usage: make cov [COV=c|swift]   (both by default)
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi
cd "$(dirname "$0")/.."
what=${1:-all}
cov=build/cov
rm -rf "$cov"
mkdir -p "$cov/bin" "$cov/prof"
prof="-fprofile-instr-generate -fcoverage-mapping"

if [ "$what" = all ] || [ "$what" = c ]; then
    # the compiler lines of make test and make roc-host (the Makefile passes
    # its variables), plus the profile flags
    san=${SAN:?make cov sets SAN}
    flags=${FLAGS:?}
    vt_src=${VT_SRC:?}
    filo_src=${FILO_SRC:?}
    roc=${ROC:-../rocchetto}
    cc=${CC:-cc}
    # shellcheck disable=SC2086
    $cc $san $prof $flags -DVT_TESTING -o "$cov/bin/test_vt" test/test_vt.c $vt_src
    # shellcheck disable=SC2086
    $cc $san $prof $flags -o "$cov/bin/test_glyph" test/test_glyph.c glyph/glyph.c
    # shellcheck disable=SC2086
    $cc $san $prof $flags -o "$cov/bin/test_pty" test/test_pty.c pty/pty.c
    # shellcheck disable=SC2086
    $cc $san $prof $flags -o "$cov/bin/test_cfg" test/test_cfg.c config/cfg.c $filo_src
    make -s roc-host >/dev/null
    # shellcheck disable=SC2046,SC2086
    $cc $san $prof -Wall -Wextra -Irochost $(cat "$roc/build/libroc.cflags") \
        -DROC_FIXTURES="\"$(cd "$roc" && pwd)/test/fixtures/utilities.txt\"" \
        -DROC_COMMANDS="\"$(cd "$roc" && pwd)/commands/bin\"" \
        -o "$cov/bin/test_rochost" test/test_rochost.c rochost/host.c build/roc-san/*.o
    for t in test_vt test_glyph test_pty test_cfg test_rochost; do
        LLVM_PROFILE_FILE="$cov/prof/$t.%p.profraw" "$cov/bin/$t" >"$cov/$t.log" 2>&1 ||
            { tail -5 "$cov/$t.log"; exit 1; }
    done
    xcrun llvm-profdata merge -sparse -o "$cov/c.profdata" "$cov"/prof/*.profraw
    xcrun llvm-cov report -instr-profile="$cov/c.profdata" \
        "$cov/bin/test_vt" -object "$cov/bin/test_glyph" -object "$cov/bin/test_pty" \
        -object "$cov/bin/test_cfg" -object "$cov/bin/test_rochost" \
        vt/vt.c vt/grid.c vt/input.c glyph/glyph.c pty/pty.c config/cfg.c rochost/host.c >"$cov/c.txt"
    printf 'C      %s\n' "$(awk '/^TOTAL/ { print $10, "lines", $4, "regions" }' "$cov/c.txt")"
fi

if [ "$what" = all ] || [ "$what" = swift ]; then
    (cd swift && perl -e 'alarm shift; exec @ARGV' 1800 swift test --no-parallel --enable-code-coverage >"../$cov/swift-test.log" 2>&1) ||
        { tail -20 "$cov/swift-test.log"; exit 1; }
    bin=$(cd swift && swift build --show-bin-path)
    profdata=$(cd swift && swift test --show-codecov-path | sed 's|/[^/]*$|/default.profdata|')
    set -- "$bin/FosforoCoreTests.xctest/Contents/MacOS/FosforoCoreTests"
    for t in FosforoRenderTests FosforoSSHTests FosforoMoshTests; do
        set -- "$@" -object "$bin/$t.xctest/Contents/MacOS/$t"
    done
    xcrun llvm-cov report -instr-profile="$profdata" "$@" \
        -ignore-filename-regex='(/Tests/|\.build/|/Frameworks/|/Sources/fosforo/|/Sources/fosforo-ios/)' >"$cov/swift.txt"
    printf 'Swift  %s\n' "$(awk '/^TOTAL/ { print $10, "lines", $4, "regions" }' "$cov/swift.txt")"
fi
echo "per file: $cov/c.txt $cov/swift.txt"
