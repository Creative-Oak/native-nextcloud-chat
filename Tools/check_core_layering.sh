#!/usr/bin/env bash
# Sources/TalkCore is the non-UI half of the app, and stays that way: no SwiftUI, AppKit,
# UIKit or Observation. A Mac build can't enforce it, since every one of those is there to
# import, so this does.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(SwiftUI|AppKit|UIKit|Observation)\b' Sources/TalkCore; then
    echo "Sources/TalkCore must not import a UI framework (see docs/ARCHITECTURE.md, hard rule 3)." >&2
    exit 1
fi
