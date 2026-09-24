#!/usr/bin/env bash
# Every string kvidr shows is in its catalog and translated into every language there.
#
# Needs a Debug build of the app first (preflight does one): the compiler writes the strings
# it found into .stringsdata files, which are merged into a copy of Localizable.xcstrings —
# what Xcode does to the catalog itself when it builds — and the copy is checked.
#
#   ./Tools/check_translations.sh           check (exits 1 on anything missing)
#   ./Tools/check_translations.sh --write   also merge new strings into the catalog, to translate
#
# OBJECTS_DIR=<…/Objects-normal> picks the build to read, when it isn't Xcode's usual one.
set -euo pipefail
cd "$(dirname "$0")/.."

write=false
[[ "${1:-}" == "--write" ]] && write=true

catalog=Kvidr/Resources/Localizable.xcstrings
objects="${OBJECTS_DIR:-}"
if [[ -z "$objects" ]]; then
    objects=$(xcodebuild -showBuildSettings -project Kvidr.xcodeproj -scheme Kvidr -configuration Debug \
        -destination 'platform=macOS' 2>/dev/null | awk -F' = ' '/ OBJECT_FILE_DIR_normal = / { print $2; exit }')
fi
stringsdata=()
while IFS= read -r file; do stringsdata+=("$file"); done < <(find "$objects" -name '*.stringsdata' 2>/dev/null)
if [[ ${#stringsdata[@]} -eq 0 ]]; then
    echo "No .stringsdata under $objects — build the app first." >&2
    exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# The table is named after the file, so the copy keeps the name.
cp "$catalog" "$scratch/Localizable.xcstrings"
# Its notices (one English key, several comments) are fine, and would drown the report.
{ xcrun xcstringstool sync "$scratch/Localizable.xcstrings" --stringsdata "${stringsdata[@]}" 2>&1; } \
    | { grep -v '^notice: ' || true; }

if $write; then
    cp "$scratch/Localizable.xcstrings" "$catalog"
    echo "Merged the build's strings into $catalog."
fi

status=0
xcrun swift Tools/check_translations.swift "$catalog" "$scratch/Localizable.xcstrings" || status=1
xcrun swift Tools/check_translations.swift Kvidr/Resources/InfoPlist.xcstrings || status=1
xcrun swift Tools/check_translations.swift Kvidr/Integrations/AppShortcuts.xcstrings || status=1
exit $status
