# Mac handover

Everything in this repository was written on Linux, where there is no macOS SDK. **Xcode
has never built this app**, and no Nextcloud server has ever answered one of its requests.

That is the one thing to keep in mind while reading the rest: the app is *verified* to a
degree that is unusual for code that has never run, and *unproven* in the ways that only a
Mac and a real server can settle. This document is the handover between those two states —
what has been checked and how, what is still open, what to do in what order, and what to
send back when something goes wrong.

---

## 1. What you are getting

A v1.0 native macOS client for Nextcloud Talk's text chat — 91 Swift files and about
14,000 lines of it, plus 16 test files, split in two:

| | |
| --- | --- |
| `Sources/TalkCore/` | Everything that isn't UI: models, OCS networking, services, the two sync engines, message rendering, the SwiftData cache, the Keychain wrapper. A Swift package, so it builds and tests on Linux — which is what has kept it free of any UI dependency. |
| `Kvidr/` | SwiftUI and AppKit. The app target. |

Both are in the Xcode target through Xcode 16+ **synchronized folder groups**, so there is
no file list to maintain — new files appear in the target automatically.

`docs/PRODUCT.md`, `docs/ARCHITECTURE.md` and `docs/NEXTCLOUD_API.md` cover what it is,
how it is put together, and every endpoint and capability it relies on. `CHANGELOG.md`
lists what is in 1.0 and what deliberately isn't.

---

## 2. What has been verified, and how

`./Tools/preflight.sh` runs everything that can be checked without a Mac. It passes, and
the same checks run in CI on every push:

| Check | What it proves |
| --- | --- |
| `swift build && swift test` — **213 tests** | The whole non-UI application is correct against recorded fixtures: OCS decoding, the merge rules, both sync engines, read-state policy, login flow, message parsing, every service's request shape. |
| `Tools/uicheck/run.sh` | **The app target type-checks under Swift 6**, against stand-in SwiftUI/AppKit/SwiftData modules. |
| `Tools/check_imports.py` | Every file importing a framework it actually uses. Caught four certain errors. |
| `Tools/validate_pbxproj.py` | The Xcode project parses and its synchronized groups are intact. |

### About the type-check

`Tools/uicheck` builds modules *named* SwiftUI, AppKit, SwiftData, Combine,
UniformTypeIdentifiers and UserNotifications. They are not implementations — they are a
declaration of the API surface this app uses, deliberately faithful about **names, argument
labels and actor isolation**, because those are what break a build. The real app sources
are then type-checked against them with `-swift-version 6`.

It found nineteen errors that would each have been an error in Xcode, among them a
recursive `some View` whose opaque type was defined in terms of itself, an `EnvironmentKey`
whose `defaultValue` held a non-Sendable closure, and an actor-isolated method trying to
satisfy a nonisolated protocol requirement.

**When the stub and your SDK disagree, your SDK is right.** Fix the app, then fix
`Tools/uicheck/stubs/SwiftUI.swift` to match, so the next run catches the same thing.

### What no amount of Linux can check

Four areas, and the first build's errors will be concentrated in them:

1. **SwiftData** — `Sources/TalkCore/Persistence/CacheModels.swift`. Macros can't be
   stood in for, so this file is only *parsed* here. The schema is deliberately tiny: five
   models, scalar columns plus an encoded payload.
2. **The Keychain** — `Sources/TalkCore/Security/KeychainStore.swift`. Security.framework,
   same reason.
3. **Liquid Glass** — the declarations are type-checked against the stub, but how
   `glassEffect`, `GlassEffectContainer` and `.buttonStyle(.glass)` actually *render* is
   not. `Kvidr/UI/Design/GlassStyle.swift` is the single place to adjust them.
4. **Runtime behaviour** — layout, animation, scroll position, focus, and every
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

If Xcode refuses to open the project at all, that is a different problem from a build
error. Run the validator and send me its output:

```sh
python3 Tools/validate_pbxproj.py Kvidr.xcodeproj/project.pbxproj
```

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
| SwiftData macro errors in `CacheModels.swift` | The likeliest place to need a fix — macros can't be stood in for, so this file is only parsed here |
| `KeychainStore.swift` errors | Same reason: Security.framework has no stand-in |
| Anything about `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` | The Liquid Glass APIs. Declarations came from Apple's documentation rather than memory and are checked against the stub, but they are new; `UI/Design/GlassStyle.swift` is the single place to adjust them |
| `cannot find type 'X' in scope` in `Kvidr/` | A core type that didn't make it into the target — check the synchronized group still covers `Sources/TalkCore` |
| A SwiftUI signature mismatch anywhere else | The stub said one thing and your SDK says another. Fix the app, then the stub |
| `main actor-isolated ... cannot be referenced` | Swift 6 concurrency. The stub models isolation, so this should be rare; the fix is almost always a capture list, not a `@preconcurrency` import |

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

On a Mac, Xcode is the authority — a real build beats any of this. But CI still runs the
Linux checks on every push, so keep them passing:

```sh
swift build && swift test                # works anywhere
python3 Tools/check_imports.py           # works anywhere
python3 Tools/validate_pbxproj.py Kvidr.xcodeproj/project.pbxproj
```

`Tools/uicheck/run.sh` is the odd one out: it exists for machines with no macOS SDK, and I
have only ever run it on Linux. On a Mac it may or may not prefer its stub modules over the
real frameworks, and it does not matter either way — you have Xcode. If you add a SwiftUI
API the stubs don't declare, the Linux CI job will tell you, and the fix is to add it to
`Tools/uicheck/stubs/`, never to change the app to suit the stub.

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

## 6. Known gaps

- **Calls** are deliberately out of scope for v1. `docs/ARCHITECTURE.md` § Room for calls
  describes what is left open for them.
- Typing indicators and user-status editing need Talk's signaling API, which is not a
  documented stable client API.
- Polls and voice messages are *shown*, not yet answered or played. Pins and reminders are
  not implemented.
- There is no `LICENSE` file — choosing one is yours to do. See the README.
