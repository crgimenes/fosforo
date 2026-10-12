#!/bin/sh
# What a release was built from: fosforo and each sibling repository at its
# commit ("dirty" when it had changes), then the SHA-256 of each file given.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "usage: tools/manifest.sh [file...]"
    echo "Prints, from the fosforo directory: one line per repository, name commit [dirty],"
    echo "then shasum -a 256 of each file."
    echo "example: tools/manifest.sh build/fosforo.ipa >build/fosforo.ipa.manifest"
    exit 0
fi

for repo in . ../rocchetto ../filo-term ../clang_filo ../edt ../corewar; do
    [ -e "$repo/.git" ] || continue
    dirty=""
    [ -z "$(git -C "$repo" status --porcelain)" ] || dirty=" dirty"
    echo "$(basename "$(cd "$repo" && pwd)") $(git -C "$repo" rev-parse HEAD)$dirty"
done
for f in "$@"; do
    shasum -a 256 "$f"
done
