#!/bin/sh
# Builds swift/Frameworks/CFosforo.xcframework: the C core for macOS, iOS
# and the iOS simulator, so one Swift package serves all three.
# usage: tools/xcframework.sh <cc> <c-flags> -- <sources...>
# pty.c is left out of the iOS slices: iOS has no fork. ROC_SRC and
# ROC_FLAGS add rocchetto and its host to the iOS slices only.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "usage: tools/xcframework.sh <cc> <c-flags> -- <sources...>"
    echo "Writes swift/Frameworks/CFosforo.xcframework (macOS, iOS, iOS simulator)."
    exit 0
fi

cc=$1
flags=$2
shift 3

out=build/xc
rm -rf "$out" swift/Frameworks/CFosforo.xcframework
mkdir -p "$out/include" swift/Frameworks
cp vt/vt.h glyph/glyph.h pty/pty.h config/cfg.h rochost/host.h "$out/include/"
cat >"$out/include/module.modulemap" <<'MAP'
module CFosforo {
    header "vt.h"
    header "glyph.h"
    header "pty.h"
    header "cfg.h"
    header "host.h"
    export *
}
MAP

# The Mac's slice is universal: macos (arm64) and macos-x86 are built apart
# and joined by lipo below; one download runs on both.
args=""
for slice in macos:macosx:arm64-apple-macos14.0 macos-x86:macosx:x86_64-apple-macos14.0 \
    ios:iphoneos:arm64-apple-ios17.0 ios-sim:iphonesimulator:arm64-apple-ios17.0-simulator; do
    name=${slice%%:*}
    rest=${slice#*:}
    sdk=${rest%%:*}
    target=${rest#*:}
    mkdir -p "$out/$name/obj"
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    for src in "$@"; do
        case "$name:$src" in ios*:*pty.c) continue ;; esac
        obj="$out/$name/obj/$(basename "$src" .c).o"
        # shellcheck disable=SC2086 # flags is a list on purpose
        $cc $flags -target "$target" -isysroot "$sysroot" -c "$src" -o "$obj"
    done
    # iOS runs rocchetto in-process (no processes to start there): its sources with
    # its own flags; one it shares with the above (Filo, utf8) is there already
    case "$name" in ios*)
        for src in ${ROC_SRC:-}; do
            obj="$out/$name/obj/$(basename "$src" .c).o"
            [ -f "$obj" ] && continue
            # shellcheck disable=SC2086 # ROC_FLAGS is a list on purpose
            $cc -O2 $ROC_FLAGS -target "$target" -isysroot "$sysroot" -c "$src" -o "$obj"
        done
        ;;
    esac
    ar rcs "$out/$name/libfosforo.a" "$out/$name"/obj/*.o
    case "$name" in
    macos) ;;
    macos-x86)
        lipo -create -output "$out/macos-universal.a" "$out/macos/libfosforo.a" "$out/macos-x86/libfosforo.a"
        mkdir -p "$out/mac"
        mv "$out/macos-universal.a" "$out/mac/libfosforo.a"
        args="$args -library $out/mac/libfosforo.a -headers $out/include"
        ;;
    *) args="$args -library $out/$name/libfosforo.a -headers $out/include" ;;
    esac
done
# shellcheck disable=SC2086 # args is a list on purpose
xcodebuild -create-xcframework $args -output swift/Frameworks/CFosforo.xcframework >/dev/null
echo "swift/Frameworks/CFosforo.xcframework"
