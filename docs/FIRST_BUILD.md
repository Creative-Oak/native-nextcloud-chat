# First build

This project was written on Linux, where there is no macOS SDK. Everything in
`Sources/TalkCore` is compiled and tested on every change (178 tests), but the SwiftUI and
AppKit layer in `TalkForMac/` has never been through a real compiler locally — only
`swiftc -parse` (syntax) and the macOS CI job.

So the first build on your Mac is a real step, not a formality. This is how to get through
it quickly.

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
| `cannot find type 'X' in scope` in `TalkForMac/` | A core type that didn't make it into the target — check the synchronized group covers `Sources/TalkCore` |
| `no exact matches in call to instance method 'onScrollGeometryChange'` | The scroll-geometry API shape differs on your SDK; the closure is in `ChatView.transcript` |
| Anything about `searchFocused`, `defaultScrollAnchor`, `onKeyPress` | macOS-version-gated SwiftUI APIs — all are macOS 15+ and the target is 26, so this would mean a signature change |
| `main actor-isolated ... cannot be referenced` | Swift 6 concurrency; the fix is almost always a capture list, not a `@preconcurrency` import |
| SwiftData macro errors in `CacheModels.swift` | The one file no Linux compiler has ever seen. Its schema is deliberately tiny — five models, scalar columns plus an encoded payload |

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
