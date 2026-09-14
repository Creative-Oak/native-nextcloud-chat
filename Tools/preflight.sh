#!/usr/bin/env bash
# Everything that can be checked without a Mac. Run before pushing.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Core build and tests"
swift build
swift test

echo "==> Type check of the app target"
# Against stub SwiftUI/AppKit modules — see Tools/uicheck/run.sh. Not a substitute for a
# real build, but it catches the mistakes that would otherwise surface as a wall of errors
# the first time the project is opened in Xcode.
./Tools/uicheck/run.sh

echo "==> Imports"
python3 Tools/check_imports.py

echo "==> Xcode project"
python3 Tools/validate_pbxproj.py Kvidr.xcodeproj/project.pbxproj

echo
echo "All checks that don't need a Mac have passed."
echo "The macOS build, the Liquid Glass rendering and the SwiftData layer still need a Mac."
