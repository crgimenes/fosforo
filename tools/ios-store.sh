#!/bin/sh
# Builds fosforo for the App Store: the iPhone/iPad app signed with the Apple
# Distribution certificate and an App Store provisioning profile, packed as
# build/fosforo.ipa. Nothing is sent; uploading is a separate step.
# Beside it: the dSYM zipped (crash reports of this build symbolicate with
# it) and a manifest of the commits and hashes it came from.
# usage: PROFILE=path/to/store.mobileprovision tools/ios-store.sh
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "usage: PROFILE=f tools/ios-store.sh"
    echo "Writes build/fosforo.ipa for App Store Connect (TestFlight, review), with"
    echo "build/fosforo-ios.dSYM.zip and build/fosforo.ipa.manifest beside it."
    echo "  PROFILE=f   the App Store provisioning profile (required)"
    echo "  BUILD=n     CFBundleVersion (default: commits on HEAD; must grow per upload)"
    echo "example: PROFILE=~/Downloads/fosforo.mobileprovision tools/ios-store.sh"
    exit 0
fi

profile=${PROFILE:?PROFILE: the App Store provisioning profile (see -h)}
out=build/store
app=$out/Payload/fosforo.app
ipa=build/fosforo.ipa
dsym=build/fosforo-ios.dSYM.zip
manifest=$ipa.manifest
last=$(sed -n 's/^build //p' "$manifest" 2>/dev/null || true)
rm -rf "$out" "$ipa" "$dsym"
mkdir -p "$out"

security cms -D -i "$profile" >"$out/profile.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$out/profile.plist" 2>/dev/null; }
if pb ProvisionedDevices >/dev/null || [ "$(pb Entitlements:get-task-allow)" != "false" ]; then
    echo "ios-store: $profile is not an App Store profile (it lists devices or allows debugging)" >&2
    exit 1
fi
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" assets/Info-iOS.plist)
team=$(pb TeamIdentifier:0)
if [ "$(pb Entitlements:application-identifier)" != "$team.$bundle" ]; then
    echo "ios-store: the profile is not for $bundle" >&2
    exit 1
fi
icloud=$(pb Entitlements:com.apple.developer.icloud-container-identifiers:0 || true)
icloud_keys=""
if [ -n "$icloud" ]; then
    icloud_keys="<key>com.apple.developer.icloud-container-identifiers</key><array><string>$icloud</string></array>
  <key>com.apple.developer.ubiquity-container-identifiers</key><array><string>$icloud</string></array>
  <key>com.apple.developer.icloud-services</key><array><string>CloudDocuments</string></array>
  <key>com.apple.developer.icloud-container-environment</key><string>Production</string>"
fi
cat >"$out/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>$team.$bundle</string>
  <key>com.apple.developer.team-identifier</key><string>$team</string>
  <key>get-task-allow</key><false/>
  <key>beta-reports-active</key><true/>
  <key>keychain-access-groups</key><array><string>$team.$bundle</string></array>
  $icloud_keys
</dict>
</plist>
EOF

(cd swift && xcodebuild -scheme fosforo-ios -destination 'generic/platform=iOS' ARCHS=arm64 \
    -configuration Release -derivedDataPath ../build/dd-store CODE_SIGNING_ALLOWED=NO \
    CLANG_ENABLE_CODE_COVERAGE=NO ENABLE_CODE_COVERAGE=NO -quiet build)
mkdir -p "$app"
products=build/dd-store/Build/Products/Release-iphoneos
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
minos=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" assets/Info-iOS.plist)
# The link of the package's executable records the deployment target as its
# SDK (17.0 where 27.0 was used), and App Store Connect refuses an old SDK:
# the binary says which SDK it was really built against. Only that record
# is rewritten: the objects must have been compiled against this SDK.
for o in "$products"/Fosforo*.o; do
    built=$(xcrun vtool -show-build "$o" | awk '$1 == "sdk" { print $2; exit }')
    if [ "$built" != "$sdk" ]; then
        echo "ios-store: $o was built against SDK $built, not $sdk" >&2
        exit 1
    fi
done
xcrun vtool -set-build-version ios "$minos" "$sdk" -replace \
    -output "$app/fosforo" "$products/fosforo-ios"
fail() {
    echo "ios-store: $1" >&2
    exit 1
}
[ "$(lipo -archs "$app/fosforo")" = arm64 ] || fail "not arm64 only"
shown=$(xcrun vtool -show-build "$app/fosforo")
echo "$shown" | grep -q "minos $minos" || fail "minos is not $minos"
echo "$shown" | grep -q "sdk $sdk" || fail "sdk is not $sdk"
if otool -l "$app/fosforo" | grep -q __llvm_prf; then fail "coverage counters in the binary"; fi
uuid=$(dwarfdump --uuid "$app/fosforo" | awk '{ print $2 }')
[ "$(dwarfdump --uuid "$products/fosforo-ios.dSYM" | awk '{ print $2 }')" = "$uuid" ] ||
    fail "the dSYM is not this binary's"
ditto -c -k --keepParent "$products/fosforo-ios.dSYM" "$dsym"
plist=$app/Info.plist
cp assets/Info-iOS.plist "$plist"
set_key() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"; }
/usr/libexec/PlistBuddy -c "Set :CFBundleSupportedPlatforms:0 iPhoneOS" "$plist"
set_key CFBundleVersion "${BUILD:-$(git rev-list --count HEAD)}"

# What Xcode writes into every bundle it builds; App Store Connect reads it
# to know the toolchain and SDK.
xcode=$(dirname "$(xcode-select -p)")
sdk_build=$(xcrun --sdk iphoneos --show-sdk-build-version)
set_key DTPlatformName iphoneos
set_key DTPlatformVersion "$sdk"
set_key DTPlatformBuild "$sdk_build"
set_key DTSDKName "iphoneos$sdk"
set_key DTSDKBuild "$sdk_build"
set_key DTXcode "$(plutil -extract DTXcode raw "$xcode/Info.plist")"
set_key DTXcodeBuild "$(plutil -extract ProductBuildVersion raw "$xcode/version.plist")"
set_key DTCompiler com.apple.compilers.llvm.clang.1_0
set_key BuildMachineOSBuild "$(sw_vers -buildVersion)"

# The icon as the store wants it: an asset catalog (one 1024 image, every
# size derived), compiled into Assets.car; its plist keys replace the loose
# files the simulator and device builds list.
set=$out/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set"
cp build/icons/Marketing1024.png "$set/icon.png"
cat >"$out/Assets.xcassets/Contents.json" <<EOF
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF
cat >"$set/Contents.json" <<EOF
{
  "images" : [ { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
xcrun actool "$out/Assets.xcassets" --compile "$app" --platform iphoneos \
    --minimum-deployment-target "$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$plist")" \
    --target-device iphone --target-device ipad --app-icon AppIcon \
    --output-partial-info-plist "$out/icon.plist" --output-format human-readable-text >"$out/actool.txt"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" -c "Delete :CFBundleIcons~ipad" "$plist"
/usr/libexec/PlistBuddy -c "Merge $out/icon.plist" "$plist"
plutil -lint "$plist" >/dev/null

if [ -f "${FONT_3270:-}" ]; then cp "$FONT_3270" "$app/"; fi
cp assets/banner.ans assets/banner-narrow.ans assets/PrivacyInfo.xcprivacy "$app/"
cp "$profile" "$app/embedded.mobileprovision"
codesign --force --sign "Apple Distribution: $(pb TeamName) ($team)" \
    --entitlements "$out/entitlements.plist" --generate-entitlement-der --timestamp=none "$app"
codesign --verify --strict --deep "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -extract get-task-allow raw - |
    grep -qx false || fail "debuggable (get-task-allow)"
plutil -lint "$app/PrivacyInfo.xcprivacy" >/dev/null || fail "no privacy manifest in the bundle"
(cd "$out" && zip -qr -X ../fosforo.ipa Payload)
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
if [ -n "$last" ] && [ "$build" -le "$last" ]; then
    echo "ios-store: build $build is not above the last one made here ($last): set BUILD to upload it" >&2
fi
{
    echo "version $version"
    echo "build $build"
    echo "sdk $sdk"
    echo "uuid $uuid"
    tools/manifest.sh "$ipa" "$dsym"
} >"$manifest"
echo "$ipa: $bundle $version ($build)${icloud:+, $icloud}; $dsym, $manifest"
