# Mac handover

Everything in this repository was written on Linux, where there is no macOS SDK. Xcode has
since built it — clean on the first attempt, under Xcode 26.3 — but **no Nextcloud server
has ever answered one of its requests**.

That is the one thing to keep in mind while reading the rest: the app is *verified* to a
degree that is unusual for code that has barely run, and *unproven* in the ways that only a
real server can settle. This document is the handover between those two states —
what has been checked and how, what is still open, what to do in what order, and what to
send back when something goes wrong.

---

## 1. What you are getting

A v1.0 native macOS client for Nextcloud Talk's text chat — 91 Swift files and about
14,000 lines of it, plus 16 test files, split in two:

| | |
| --- | --- |
| `Sources/TalkCore/` | Everything that isn't UI: models, OCS networking, services, the two sync engines, message rendering, the SwiftData cache, the Keychain wrapper. A Swift package, so it builds and tests from the command line; `Tools/check_core_layering.sh` keeps it free of any UI dependency. |
| `Kvidr/` | SwiftUI and AppKit. The app target. |

Both are in the Xcode target through Xcode 16+ **synchronized folder groups**, so there is
no file list to maintain — new files appear in the target automatically.

`docs/PRODUCT.md`, `docs/ARCHITECTURE.md` and `docs/NEXTCLOUD_API.md` cover what it is,
how it is put together, and every endpoint and capability it relies on. `CHANGELOG.md`
lists what is in 1.0 and what deliberately isn't.

---

## 2. What has been verified, and how

`./Tools/preflight.sh` runs the same checks as CI:

| Check | What it proves |
| --- | --- |
| `swift test` | The whole non-UI application is correct against recorded fixtures: OCS decoding, the merge rules, both sync engines, read-state policy, login flow, message parsing, every service's request shape. |
| `xcodebuild build` | The app target compiles against the real SDK. |
| `Tools/check_core_layering.sh` | `Sources/TalkCore` imports no UI framework. |

### What no compiler can check

1. **Liquid Glass** — how `glassEffect`, `GlassEffectContainer` and `.buttonStyle(.glass)`
   actually *render*. `Kvidr/UI/Design/GlassStyle.swift` is the single place to adjust them.
2. **Runtime behaviour** — layout, animation, scroll position, focus, and every
   interaction with a real server. No type checker has an opinion about these.

---

## 3. Getting it running

### Prerequisites

- macOS 26 (Tahoe) or later — the deployment target is 26.0 and nothing lower is supported
- Xcode 26 or later
- A Nextcloud server with the Talk app installed, reachable over HTTPS
- An Apple ID in Xcode (a free personal team is enough — see signing below)

### Step 1 — Build

```sh
git clone <this repo> && cd native-nextcloud-chat
open Kvidr.xcodeproj
```

⌘B.

While the app target is broken you can still work on everything else with
`open Package.swift`, which opens only `Sources/TalkCore` and its tests.

### Step 2 — Signing

**Select your team**: Kvidr target → Signing & Capabilities → Team. Signing style is
already Automatic and the hardened runtime is on.

The bundle identifier is `app.kvidr.mac`. If that clashes with something you
already have, or a free personal team refuses it, change `PRODUCT_BUNDLE_IDENTIFIER` and
nothing else — the Keychain's service name is read from the running bundle, so it follows
along. (Changing it does orphan credentials stored under the old identifier: you sign in
again, and the old app password is still revocable in Nextcloud's device list.)

The entitlements (`Kvidr.entitlements`) are set and should not need touching:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | On. A messaging client has no business reading your disk. |
| `com.apple.security.network.client` | Outgoing only. There is no server socket anywhere in this app. |
| `com.apple.security.files.user-selected.read-only` | So you can attach a file you picked. |

**Do not run it unsigned.** With "Sign to Run Locally" and no team, the Keychain refuses
generic-password items with `errSecMissingEntitlement` (−34018) and notification
registration fails — both of which look like app bugs and are not.

### Step 3 — Sign in

⌘R. Enter your server address — a URL copied straight out of the Talk web UI is fine, it
gets reduced to the server root.

The app uses **Login Flow v2**: it opens your browser, you approve there, and the app
receives a device-specific app password. Your Nextcloud password is never typed into, or
seen by, this app. The app password goes into the Keychain and is revoked when you remove
the account.

It appears in Nextcloud under *Settings → Security → Devices & sessions* as
`kvidr 1.0.0 (<your Mac's hostname>)`, which is also how you revoke it.

macOS will ask about notifications on first launch. Declining is fine — everything else
still works.

### Developing against a local server

For a development instance on plain HTTP, turn on **Settings → Advanced → Allow insecure
local servers**. It permits HTTP for `localhost` and private-network addresses only, never
for a public host. That is the only way to get this app to speak plain HTTP, on purpose.

---

## 4. When something goes wrong

### Build errors

| Symptom | Likely cause |
| --- | --- |
| Anything about `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` | The Liquid Glass APIs. They are new; `UI/Design/GlassStyle.swift` is the single place to adjust them |
| `cannot find type 'X' in scope` in `Kvidr/` | A core type that didn't make it into the target — check the synchronized group still covers `Sources/TalkCore` |
| `main actor-isolated ... cannot be referenced` | Swift 6 concurrency. The fix is almost always a capture list, not a `@preconcurrency` import |

Send me the first 20 or so errors rather than one at a time — they come in families, and a
batch is usually one fix repeated.

### Runtime problems

| Symptom | Where to look |
| --- | --- |
| Sign-in completes but the app asks again on relaunch | The Keychain, and almost certainly an unsigned build — see signing above. `errSecMissingEntitlement` (−34018) appears in the `auth` log category |
| Launches to an empty window and stays empty | The cache failed to open. `AppDependencies.init` falls back to an in-memory store and logs it; the conversation list should still fill from the network within a second |
| A feature is missing from a menu | That is by design: everything is gated on a server capability, not a version number. `docs/NEXTCLOUD_API.md` § 3 lists which capability gates what |
| Requests fail against a working server | Turn on verbose logging (below) and send me a request/response pair |
| Notifications never appear | System Settings → Notifications → kvidr; then Settings → Notifications in the app |

### Logs

**Settings → Advanced → Verbose logging** unlocks detail that can include message content —
off by default, deliberately. Then:

```sh
log stream --predicate 'subsystem == "app.kvidr.mac"' --level debug
```

Categories are `auth`, `api`, `sync`, `chat`, `persistence`, `notification`, `ui`. No
credential is ever logged, in any mode.

### If you change code

Run `./Tools/preflight.sh` before pushing; it is what CI runs.

---

## 5. What to judge once it runs

The things that most need your eye, because they are exactly what I could not see:

- Does the sidebar feel instant on launch, before the network answers?
- Does the transcript scroll smoothly in a long conversation, and does loading older
  messages leave your reading position alone?
- Does Return-to-send feel right, and does ⌘↑ pick up your last message?
- Do unread states agree with what the Talk web UI thinks — including after you read
  something on your phone?
- Does Liquid Glass look right, or overdone? It is applied to the floating layer only
  (message actions, panels, reaction pills, upload rows) and deliberately not to the
  transcript, which is content.
- Does ⇧⌘F find things the web UI finds?
- Does the window come back where you left it?

### The Apple Intelligence work, specifically

Added 17 September 2026 — design in
[`plans/2026-09-17-apple-intelligence-design.md`](plans/2026-09-17-apple-intelligence-design.md).
The date scanner and the suggestion rules are covered by tests (`swift test`), so the
*logic* is settled. Four things are not, and all four need a Mac:

1. **The composer's height.** `ComposerTextView.updateHeight()` used to read
   `textView.layoutManager`, which on a TextKit 2 view silently drops the view back to
   TextKit 1 — and Writing Tools' full experience needs TextKit 2. It now asks
   `textLayoutManager` first and keeps the old path as a fallback. So: does the field still
   grow line by line, stop at its ceiling and start scrolling, and does the transcript stay
   put while it does? This is the change most likely to have gone wrong.
2. **The underline.** Type `lad os snakke om det i morgen`. Is *i morgen* blue and
   underlined, does the underline move with the words as you edit around it, and does
   clicking it arm the pill rather than just moving the caret? Typing straight after an
   underlined phrase must not come out blue.
3. **The Foundation Models API surface.** `OnDeviceIntelligence` is the only file that
   imports it, written against the documented shape without an SDK to check it against:
   `SystemLanguageModel.default.availability`, `LanguageModelSession { instructions }`,
   `respond(to:generating:)`, `@Generable`/`@Guide`. If any of it has moved, it has moved in
   one file, and everything else is written to carry on without it.
4. **Reminders.app.** With Settings → Intelligence → "Reminders go to" set to Apple or
   Both, the first reminder should raise the system permission prompt — it needs both
   `com.apple.security.personal-information.calendars` in the entitlements and
   `NSRemindersFullAccessUsageDescription`, which are both in. A silent no-op means one of
   them didn't make it into the signed build.

Worth trying with Apple Intelligence **off**, too: underlined times and the one-tap chips
should all still work, and the reply row should simply not appear.

## 6. Known gaps

- **Calls** are deliberately out of scope for v1. `docs/ARCHITECTURE.md` § Room for calls
  describes what is left open for them.
- Typing indicators need Talk's signaling API, which is not a documented stable client API.
- Polls and voice messages are *shown*, not yet answered or played. Pins and reminders are
  not implemented.
- Licensed MIT. The one piece not written here is `.agents/skills/swiftui-pro/`, which is
  Paul Hudson's, also MIT, and is an agent rule set rather than part of the app.
