# First build

This project was written on Linux, where there is no macOS SDK. Xcode has never built it.
That is less alarming than it sounds — the whole app is type-checked here, under Swift 6,
against stand-in SwiftUI and AppKit modules — but the first build on your Mac is still a
real step rather than a formality. This is how to get through it quickly.

## 0. What has already been checked

`Tools/preflight.sh` runs everything that can be verified without a Mac, and passes:

```
swift build && swift test          213 tests
Tools/uicheck/run.sh               type-checks all of TalkForMac/ under -swift-version 6
Tools/check_imports.py             framework imports (this caught four certain errors)
Tools/validate_pbxproj.py          the Xcode project's integrity
```

`Tools/uicheck` builds modules named SwiftUI, AppKit, SwiftData, Combine,
UniformTypeIdentifiers and UserNotifications that declare the API surface this app uses —
names, argument labels and actor isolation, faithfully — then type-checks the real sources
against them. It found nineteen errors that would each have been an error in Xcode,
including a recursive `some View`, a non-Sendable `EnvironmentKey` default and an
actor-isolated method trying to satisfy a nonisolated protocol requirement.

What it *cannot* check is the parts with no stand-in:

- **SwiftData** (`Persistence/CacheModels.swift`) — macros, so only parsed here.
- **The Keychain** (`Security/KeychainStore.swift`) — Security.framework, likewise.
- **Liquid Glass** — the declarations are checked, but how it renders is not.
- Anything that is a *runtime* behaviour rather than a type: layout, animation, scroll
  position, focus.

So expect a short first-build pass rather than a long one, concentrated in those four
areas.

## 1. Open and build

```sh
open TalkForMac.xcodeproj
```

⌘B. The project uses Xcode 16+ synchronized folder groups, so both `TalkForMac/` and
`Sources/TalkCore/` are already in the target and new files appear automatically.

If Xcode refuses to open the project at all, run the validator and send me what it says:

```sh
python3 Tools/validate_pbxproj.py TalkForMac.xcodeproj/project.pbxproj
```

You can still work on everything except the UI in the meantime with `open Package.swift`.

## 2. What errors to expect, and what they mean

| Symptom | Likely cause |
| --- | --- |
| SwiftData macro errors in `CacheModels.swift` | The likeliest place to need a fix: macros can't be stood in for, so this file is only parsed here. Its schema is deliberately tiny — five models, scalar columns plus an encoded payload |
| `KeychainStore.swift` errors | Same reason: Security.framework has no stand-in |
| Anything about `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` | The Liquid Glass APIs. Declarations came from Apple's documentation rather than memory and are checked against the stub, but they are new; `UI/Design/GlassStyle.swift` is the single place to adjust them |
| `cannot find type 'X' in scope` in `TalkForMac/` | A core type that didn't make it into the target — check the synchronized group covers `Sources/TalkCore` |
| A SwiftUI signature mismatch anywhere else | The stub said one thing and your SDK says another. Fix the app, then fix `Tools/uicheck/stubs/SwiftUI.swift` to match, so the next run catches it |
| `main actor-isolated ... cannot be referenced` | Swift 6 concurrency. The stub models isolation, so this should be rare; the fix is almost always a capture list, not a `@preconcurrency` import |

Send me the first 20 or so errors and I'll fix them in a batch — they usually come in
families rather than one at a time.

## 3. Then run it

You'll need to sign the app with your own team (Signing & Capabilities → Team). The
entitlements are already set up: app sandbox on, outgoing network only.

Sign in with your server address. The app opens your browser for Login Flow v2; approve
there, come back, and the conversation list should populate.

## 4. What to look at first

The things most worth your judgement, because they're the ones I couldn't see:

- Does the sidebar feel instant on launch, before the network answers?
- Does the transcript scroll smoothly in a long conversation, and does loading older
  messages leave your reading position alone?
- Does Return-to-send feel right, and does ⌘↑ pick up your last message?
- Do unread states match what the Talk web UI thinks?
- Does the window come back where you left it?
