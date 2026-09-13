#!/usr/bin/env bash
# Everything that can be checked without a Mac. Run before pushing.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Core build and tests"
swift build
swift test

echo "==> Syntax check of the app target"
failed=0
while IFS= read -r file; do
    if ! output=$(swiftc -parse "$file" 2>&1) || [ -n "$output" ]; then
        echo "$output"
        failed=1
    fi
done < <(find TalkForMac -name '*.swift')
[ "$failed" -eq 0 ] || { echo "syntax errors in the app target"; exit 1; }

echo "==> Imports"
python3 Tools/check_imports.py

echo "==> Xcode project"
python3 Tools/validate_pbxproj.py TalkForMac.xcodeproj/project.pbxproj

echo
echo "All checks that don't need a Mac have passed."
echo "The SwiftUI layer is still only type-checked by Xcode or the macOS CI job."
