#!/usr/bin/env bash
# Run before pushing. On Linux this is everything that can be checked without a Mac; on a
# Mac it builds the app for real, which proves strictly more than the stub type-check can.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname)" in Darwin) MAC=1 ;; *) MAC=0 ;; esac

echo "==> Core build and tests"
swift build
swift test

if [ "$MAC" -eq 1 ]; then
    echo "==> Build of the app target"
    # The real build, which makes the stub type-check redundant here — and it is worse than
    # redundant: with a macOS SDK present, a stub module named Combine is a circular
    # dependency against the SDK's own Foundation, so Tools/uicheck cannot run on a Mac at
    # all. It stays for Linux and for CI, where it is the only check of the app target there
    # is, and where it also keeps Sources/TalkCore free of any UI dependency.
    xcodebuild build \
        -project Kvidr.xcodeproj \
        -scheme Kvidr \
        -configuration Debug \
        -destination 'platform=macOS' \
        -quiet \
        CODE_SIGNING_ALLOWED=NO
else
    echo "==> Type check of the app target"
    # Against stub SwiftUI/AppKit modules — see Tools/uicheck/run.sh. Not a substitute for a
    # real build, but it catches the mistakes that would otherwise surface as a wall of errors
    # the first time the project is opened in Xcode.
    ./Tools/uicheck/run.sh
fi

echo "==> Imports"
python3 Tools/check_imports.py

echo "==> Xcode project"
python3 Tools/validate_pbxproj.py Kvidr.xcodeproj/project.pbxproj

echo
if [ "$MAC" -eq 1 ]; then
    echo "All checks have passed, including the macOS build of the app."
    echo "How Liquid Glass renders, and every interaction with a real server, still need your eyes."
else
    echo "All checks that don't need a Mac have passed."
    echo "The macOS build, the Liquid Glass rendering and the SwiftData layer still need a Mac."
fi
