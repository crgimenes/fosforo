#!/bin/sh
# Builds fosforo for iPhone/iPad, signs it with the Apple Development
# certificate and the team's provisioning profile, and installs it on the
# paired devices (all of them, or DEVICE=<name or udid>).
# usage: tools/ios-device.sh [-n]   (-n: build and sign, do not install)
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "usage: tools/ios-device.sh [-n]"
    echo "Writes build/fosforo-device.app and installs it on the paired iOS devices."
    echo "  -n          build and sign only"
    echo "  DEVICE=x    install on one device (name or UDID)"
    echo "  PROFILE=f   provisioning profile (default: the newest one in Xcode's"
    echo "              folder that covers the bundle id)"
    echo "example: DEVICE='My iPad' tools/ios-device.sh"
    exit 0
fi

bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" assets/Info-iOS.plist)
app=build/fosforo-device.app
tmp=build/device-sign
mkdir -p "$tmp"

# a profile whose application-identifier is TEAM.<bundle> or TEAM.*
profile=${PROFILE:-}
if [ -z "$profile" ]; then
    # shellcheck disable=SC2012 # ls -t for newest first; the names are UUIDs
    for f in $(ls -t "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
        "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision 2>/dev/null | tr ' ' '\001'); do
        f=$(echo "$f" | tr '\001' ' ')
        security cms -D -i "$f" >"$tmp/profile.plist" 2>/dev/null || continue
        id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$tmp/profile.plist")
        team=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$tmp/profile.plist")
        # an App Store profile lists no devices and installs on none
        /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$tmp/profile.plist" >/dev/null 2>&1 || continue
        if [ "$id" = "$team.$bundle" ] || [ "$id" = "$team.*" ]; then
            profile=$f
            break
        fi
    done
fi
if [ -z "$profile" ]; then
    echo "ios-device: no provisioning profile covers $bundle (run any app from Xcode once)" >&2
    exit 1
fi
security cms -D -i "$profile" >"$tmp/profile.plist"
team=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$tmp/profile.plist")
# the profile's iCloud container, when the App ID has one (iCloud Drive folder)
icloud=$(/usr/libexec/PlistBuddy -c \
    "Print :Entitlements:com.apple.developer.icloud-container-identifiers:0" \
    "$tmp/profile.plist" 2>/dev/null || true)
icloud_keys=""
if [ -n "$icloud" ]; then
    icloud_keys="<key>com.apple.developer.icloud-container-identifiers</key><array><string>$icloud</string></array>
  <key>com.apple.developer.ubiquity-container-identifiers</key><array><string>$icloud</string></array>
  <key>com.apple.developer.icloud-services</key><array><string>CloudDocuments</string></array>
  <key>com.apple.developer.icloud-container-environment</key><string>Development</string>"
fi

cat >"$tmp/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>$team.$bundle</string>
  <key>com.apple.developer.team-identifier</key><string>$team</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>$team.$bundle</string></array>
  $icloud_keys
</dict>
</plist>
EOF

(cd swift && xcodebuild -scheme fosforo-ios -destination 'generic/platform=iOS' ARCHS=arm64 \
    -configuration Release -derivedDataPath ../build/dd-device CODE_SIGNING_ALLOWED=NO -quiet build)
rm -rf "$app"
mkdir -p "$app"
cp build/dd-device/Build/Products/Release-iphoneos/fosforo-ios "$app/fosforo"
cp assets/Info-iOS.plist "$app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleSupportedPlatforms:0 iPhoneOS" "$app/Info.plist"
if [ -f "${FONT_3270:-}" ]; then cp "$FONT_3270" "$app/"; fi
cp assets/banner.ans assets/banner-narrow.ans assets/PrivacyInfo.xcprivacy build/icons/AppIcon*.png "$app/"
cp "$profile" "$app/embedded.mobileprovision"
codesign --force --sign "Apple Development" --entitlements "$tmp/entitlements.plist" \
    --timestamp=none "$app"
codesign --verify --strict "$app"
echo "signed $app ($team.$bundle${icloud:+, $icloud})"

if [ "${1:-}" = "-n" ]; then
    exit 0
fi
xcrun devicectl list devices --json-output "$tmp/devices.json" >/dev/null
devices=$(python3 -c '
import json, sys
want = sys.argv[2]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("reality") != "physical":
        continue
    name = d["deviceProperties"].get("name", "")
    udid = d["hardwareProperties"].get("udid", "")
    if want in ("", name, udid):
        print(udid)
' "$tmp/devices.json" "${DEVICE:-}")
if [ -z "$devices" ]; then
    echo "ios-device: no paired device${DEVICE:+ named $DEVICE}" >&2
    exit 1
fi
for d in $devices; do
    xcrun devicectl device install app --device "$d" "$app"
done
