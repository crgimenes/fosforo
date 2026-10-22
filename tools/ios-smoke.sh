#!/bin/sh
# The iOS app run in a simulator nobody sees (no Simulator.app window): a
# throwaway iPhone is created, booted, given build/fosforo-sim.app (make
# ios-sim, a debug build), and the app is launched with FOSFORO_SMOKE, which
# has it type the steps below into its first session and write the screen
# back as text; each line in the expectations has to be on it. The device
# is deleted at the end, whatever happened.
# usage: tools/ios-smoke.sh   (exit 0 when every expectation holds)
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi
cd "$(dirname "$0")/.."
app=build/fosforo-sim.app
bundle=br.eti.crg.fosforo
[ -d "$app" ] || { echo "ios-smoke: no $app (make ios-sim)" >&2; exit 1; }

# the newest iOS runtime and an iPhone it supports (its own list: a device
# type it does not name is refused as incompatible)
pick=$(xcrun simctl list runtimes available -j | python3 -I -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS"]
if not ios:
    sys.exit(0)
r = max(ios, key=lambda r: [int(x) for x in r["version"].split(".")])
phones = [d for d in r.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
plain = [d for d in phones if "SE" not in d["name"] and not d["name"].endswith("e")]
def age(d):
    digits = "".join(c if c.isdigit() else " " for c in d["name"]).split()
    return (int(digits[0]) if digits else 0, -len(d["name"]))
pick = max(plain or phones, key=age) if phones else None
if pick:
    print(r["identifier"], pick["identifier"], pick["name"].replace(" ", "_"))')
runtime=$(echo "$pick" | cut -d" " -f1)
dtype=$(echo "$pick" | cut -d" " -f2)
dname=$(echo "$pick" | cut -d" " -f3 | tr _ " ")
[ -n "$runtime" ] && [ -n "$dtype" ] || { echo "ios-smoke: no iOS runtime or iPhone type" >&2; exit 1; }

udid=$(xcrun simctl create fosforo-smoke "$dtype" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
docs=$(xcrun simctl get_app_container "$udid" "$bundle" data)/Documents
mkdir -p "$docs"
cat >"$docs/smoke.in" <<'STEPS'
echo fosforo smoke
mkdir -p smoke-dir
cd smoke-dir
pwd
cd
ls
config
@wait 3
STEPS
SIMCTL_CHILD_FOSFORO_SMOKE=smoke.in xcrun simctl launch "$udid" "$bundle" >/dev/null

out=$docs/smoke.out
i=0
while [ ! -s "$out" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
done
[ -s "$out" ] || { echo "ios-smoke: no screen came back in 120 s" >&2; exit 1; }

failed=0
check() {
    if ! grep -qE "$1" "$out"; then
        echo "ios-smoke: not on the screen: $2" >&2
        failed=1
    fi
}
check '^fosforo smoke$' "echo's output on a line of its own"
check '/smoke-dir$' "pwd in the directory just made"
check 'README\.md' "ls shows the welcome README in the home"
check '\$ *$' "the prompt, waiting"
check '^--- presented .* ConfigController$' "config opens Settings over the terminal"
if [ "$failed" = 1 ]; then
    echo "--- the screen:" >&2
    cat "$out" >&2
    exit 1
fi
echo "ios-smoke: launch, shell, files and Settings as expected ($dname)"
