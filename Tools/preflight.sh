#!/usr/bin/env bash
# Run before pushing: the same checks CI runs.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Core stays free of UI"
./Tools/check_core_layering.sh

echo "==> Core tests"
swift test

echo "==> Build of the app target"
xcodebuild build \
    -project Kvidr.xcodeproj \
    -scheme Kvidr \
    -configuration Debug \
    -destination 'platform=macOS' \
    -quiet \
    CODE_SIGNING_ALLOWED=NO

echo
echo "All checks have passed, including the macOS build of the app."
echo "How Liquid Glass renders, and every interaction with a real server, still need your eyes."
