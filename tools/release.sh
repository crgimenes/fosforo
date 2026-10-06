#!/bin/sh
# The Mac build for people other than its developer: signed with Developer
# ID and the hardened runtime, notarized by Apple, stapled, zipped. Nothing
# is published: the zip in build/ is what a GitHub release or the Homebrew
# tap would take, when that day comes.
#
# usage: tools/release.sh [--no-notarize] [--install]
#   --no-notarize  sign and verify only (offline; Gatekeeper will still ask)
#   --install      copy the result to /Applications (a running fosforo keeps
#                  its bundle as /Applications/fosforo-old.app until relaunch)
#   APPLE_DEVELOPER_ID   certificate hash (security find-identity -v -p
#                        codesigning); default: the first Developer ID found
#   APPLE_NOTARY_PROFILE notarytool keychain profile (xcrun notarytool
#                        store-credentials NAME --apple-id ... --team-id ...)
#   VERSION              CFBundleShortVersionString (default: the plist's)
# example: APPLE_NOTARY_PROFILE=fosforo-notary tools/release.sh --install
set -eu

notarize=1
install=0
for arg in "$@"; do
    case "$arg" in
    -h | --help)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    --no-notarize) notarize=0 ;;
    --install) install=1 ;;
    *)
        echo "release.sh: unknown argument $arg (try -h)" >&2
        exit 2
        ;;
    esac
done

cd "$(dirname "$0")/.."
app=build/fosforo.app
zip=build/fosforo-macos.zip
work=build/release
mkdir -p "$work"

identity=${APPLE_DEVELOPER_ID:-}
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$identity" ]; then
    echo "release.sh: no Developer ID Application certificate in the keychain" >&2
    exit 1
fi
if [ "$notarize" = 1 ] && [ -z "${APPLE_NOTARY_PROFILE:-}" ]; then
    echo "release.sh: APPLE_NOTARY_PROFILE names the notarytool credentials (or --no-notarize)" >&2
    exit 1
fi

# the ad hoc bundle from the Makefile, then our own signature over it
make app
plist=$app/Contents/Info.plist
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
fi
# the build number grows with the history, so two builds never share one
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$plist"
plutil -lint "$plist"

# hardened runtime, no entitlements: the shell runs as a child process, which
# the runtime allows; the Metal shaders compile through the system, not JIT
codesign --force --sign "$identity" --options runtime --timestamp "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "signed $app with $identity"

if [ "$notarize" = 1 ]; then
    rm -f "$work/submission.zip"
    ditto -c -k --keepParent "$app" "$work/submission.zip"
    xcrun notarytool submit "$work/submission.zip" --keychain-profile "$APPLE_NOTARY_PROFILE" \
        --output-format plist --timeout 30m --wait >"$work/notarization.plist"
    status=$(plutil -extract status raw "$work/notarization.plist")
    if [ "$status" != "Accepted" ]; then
        id=$(plutil -extract id raw "$work/notarization.plist")
        echo "release.sh: notarization $status; the log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$APPLE_NOTARY_PROFILE" >&2 || true
        exit 1
    fi
    xcrun stapler staple -q "$app"
    xcrun stapler validate -q "$app"
    spctl --assess --type execute --verbose=2 "$app"
    echo "notarized and stapled"
fi

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip ($(du -h "$zip" | cut -f1))"

if [ "$install" = 1 ]; then
    if pgrep -xq fosforo; then
        rm -rf /Applications/fosforo-old.app
        mv /Applications/fosforo.app /Applications/fosforo-old.app 2>/dev/null || true
        echo "fosforo is running: the old bundle stays as /Applications/fosforo-old.app until relaunch"
    else
        rm -rf /Applications/fosforo.app
    fi
    cp -R "$app" /Applications/fosforo.app
    echo "installed /Applications/fosforo.app"
fi
