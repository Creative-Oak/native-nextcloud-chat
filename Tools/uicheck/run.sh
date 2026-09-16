#!/usr/bin/env bash
# Type-checks the macOS app sources on a machine with no macOS SDK.
#
# It works by building stand-in modules named SwiftUI, AppKit, and so on, then
# type-checking the real app sources against them. The stubs are not SwiftUI — they are a
# declaration of the API surface this app uses. That is enough to catch the errors that
# actually break a first build: a misspelled member on one of our own types, a wrong
# argument label, a missing initializer, an actor-isolation mistake.
#
# When this reports an error about a SwiftUI API, the fix is to add the API to the stub.
# When it reports an error about one of *our* types, the fix is in the app.
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD=".uicheck"
MODULES="$BUILD/modules"
rm -rf "$BUILD"
mkdir -p "$MODULES"

SWIFTC=${SWIFTC:-swiftc}

# Each stub is its own module, named after the framework it stands in for.
# Order matters: SwiftUI's stub imports Combine and AppKit, and PhotosUI's imports SwiftUI.
for module in Combine UniformTypeIdentifiers SwiftData AppKit LinkPresentation SwiftUI PhotosUI UserNotifications; do
    if [ -f "Tools/uicheck/stubs/$module.swift" ]; then
        # -parse-as-library: each stub is a single file, and swiftc treats a lone file as
        # top-level script code, where a global such as `NSApp` may not carry @MainActor.
        $SWIFTC -emit-module -parse-as-library -module-name "$module" \
            -emit-module-path "$MODULES/$module.swiftmodule" \
            -swift-version 6 \
            -I "$MODULES" \
            "Tools/uicheck/stubs/$module.swift" 2>&1 | sed "s|^|[$module] |"
    fi
done

# The app, plus the core it compiles alongside in Xcode, copied into a scratch tree so two
# constructs can be rewritten: `#selector(...)` and `@objc` both need Objective-C interop,
# which does not exist off Apple platforms. Nothing else about the sources is changed.
SRC="$BUILD/src"
mkdir -p "$SRC"
while IFS= read -r file; do
    target="$SRC/$(echo "$file" | tr '/' '_')"
    sed -E -e 's/#selector\(NS[A-Za-z]+\.([A-Za-z]+)\(_:\)\)/Selector("\1")/g' \
           -e 's/#selector\(([A-Za-z_][A-Za-z0-9_]*)\)/Selector("\1")/g' \
           -e 's/@objc //g' "$file" > "$target"
done < <(find Sources/TalkCore Kvidr -name '*.swift' \
    ! -path '*/Persistence/*' ! -path '*/Security/KeychainStore.swift')

cp Tools/uicheck/shims/*.swift "$SRC" 2>/dev/null || true

# shellcheck disable=SC2086
$SWIFTC -typecheck -module-name KvidrCheck \
    -swift-version 6 \
    -I "$MODULES" \
    "$SRC"/*.swift

# The two files left out above need SwiftData and the macOS Keychain, neither of which can
# be stood in for convincingly. They at least get parsed, so a syntax error still shows up
# here rather than in Xcode.
failed=0
while IFS= read -r file; do
    if ! output=$($SWIFTC -parse "$file" 2>&1) || [ -n "$output" ]; then
        echo "$output"
        failed=1
    fi
done < <(find Sources/TalkCore Kvidr -name '*.swift' \
    \( -path '*/Persistence/*' -o -path '*/Security/KeychainStore.swift' \))
[ "$failed" -eq 0 ] || { echo "syntax errors in the files that can only be parsed"; exit 1; }
