#!/bin/sh
# Builds fosforo for the App Store: the iPhone/iPad app signed with the Apple
# Distribution certificate and an App Store provisioning profile, packed as
# build/fosforo.ipa. Nothing is sent; uploading is a separate step.
# usage: PROFILE=path/to/store.mobileprovision tools/ios-store.sh
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "usage: PROFILE=f tools/ios-store.sh"
    echo "Writes build/fosforo.ipa for App Store Connect (TestFlight, review)."
    echo "  PROFILE=f   the App Store provisioning profile (required)"
    echo "  BUILD=n     CFBundleVersion (default: commits on HEAD; must grow per upload)"
    echo "example: PROFILE=~/Downloads/fosforo.mobileprovision tools/ios-store.sh"
    exit 0
fi

profile=${PROFILE:?PROFILE: the App Store provisioning profile (see -h)}
out=build/store
app=$out/Payload/fosforo.app
ipa=build/fosforo.ipa
rm -rf "$out" "$ipa"
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
    -configuration Release -derivedDataPath ../build/dd-store CODE_SIGNING_ALLOWED=NO -quiet build)
mkdir -p "$app"
cp build/dd-store/Build/Products/Release-iphoneos/fosforo-ios "$app/fosforo"
plist=$app/Info.plist
cp assets/Info-iOS.plist "$plist"
set_key() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"; }
/usr/libexec/PlistBuddy -c "Set :CFBundleSupportedPlatforms:0 iPhoneOS" "$plist"
set_key CFBundleVersion "${BUILD:-$(git rev-list --count HEAD)}"

# What Xcode writes into every bundle it builds; App Store Connect reads it
# to know the toolchain and SDK.
xcode=$(dirname "$(xcode-select -p)")
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
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
cp assets/banner.ans assets/PrivacyInfo.xcprivacy "$app/"
cp "$profile" "$app/embedded.mobileprovision"
codesign --force --sign "Apple Distribution: $(pb TeamName) ($team)" \
    --entitlements "$out/entitlements.plist" --generate-entitlement-der --timestamp=none "$app"
codesign --verify --strict --deep "$app"
(cd "$out" && zip -qr -X ../fosforo.ipa Payload)
echo "$ipa: $bundle $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist") ($(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist"))${icloud:+, $icloud}"
