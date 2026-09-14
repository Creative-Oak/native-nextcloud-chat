# kvidr

A native macOS client for [Nextcloud Talk](https://nextcloud.com/talk/), focused on text
chat. Swift and SwiftUI, with AppKit where AppKit behaves better. No Electron, no web view
rendering chat content — it talks to the documented Nextcloud and Talk HTTP APIs directly.

The benchmark is Messages.app: instant launch from cache, native scrolling and selection,
real menu commands, keyboard-first navigation, unread state you can trust.

> **Status:** v1.0 — chat, complete. Calls are deliberately out of scope for v1; the
> architecture leaves room for them.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- A Nextcloud server with the Talk app installed

## Building

```sh
open Kvidr.xcodeproj      # then ⌘R
```

The project uses Xcode 16+ synchronized folder groups, so new files under `Kvidr/`
and `Sources/TalkCore/` are picked up automatically — there is no file list to maintain.

`./Tools/preflight.sh` is the check to run before pushing: the core build and its tests, the
framework-import check, and the Xcode project's integrity — plus the app target, which it
builds with Xcode on a Mac and type-checks against stand-in SwiftUI/AppKit modules where
there is no macOS SDK. All of it runs in CI too, on both platforms.

The non-UI half of the app is also a Swift package, so it builds and tests from the
command line — including on Linux, which is what keeps the layering honest:

```sh
swift build
swift test
```

## Signing in

kvidr uses **Login Flow v2**: you enter your server address, approve the app in your
browser, and the app receives a device-specific app password. Your Nextcloud password is
never typed into, or seen by, this app. The app password is stored in the macOS Keychain and
is revoked when you remove the account.

## What works

**Chat** — accounts (Login Flow v2, Keychain, capability discovery) · conversation list with
avatars, favourites, unread and mention state, grouped into Favourites / Conversations /
Archived · chat history with backwards pagination, grouping, day separators and a
new-messages marker · Markdown, mentions, links, files and rich objects · sending with
optimistic delivery and retry · replies, reactions (and who reacted), editing and deleting ·
read markers that only move when you have actually seen a message · live updates over Talk's
long poll · notifications and Dock badge · local cache, drafts, offline reading.

**Beyond chat** — a third-column inspector with conversation info, participants (invite and
remove) and shared files · ⌘N new conversation, with Nextcloud's own people search ·
attachments by drag-and-drop, ⇧⌘A or paste, with real upload progress · images inline with
an in-app viewer · ⌥⌘F find in conversation · ⌘K quick switcher · moderator settings
(rename, description, read-only, message expiration, link access) · ⇧⌘F server-side search
across your whole message history · a keyboard shortcuts window.

**Design** — Liquid Glass on macOS 26, applied to the floating layer (message actions,
panels, reaction pills, upload rows) and deliberately *not* to the transcript, which is
content. See `docs/ARCHITECTURE.md` § Liquid Glass.

Everything is gated on server capabilities rather than version numbers, so a feature your
server doesn't support is hidden rather than broken.

## Keyboard

| Shortcut | Action |
| --- | --- |
| ⌘F | Search conversations |
| ↑ ↓ | Move through the sidebar |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next conversation |
| ⇧⌘] | Next unread conversation |
| ⌘K | Go to conversation (quick switcher) |
| ⇧⌘K | Focus the message field |
| @ | Mention someone — ↑↓ to choose, Return or Tab to insert |
| Return | Send (⇧Return for a new line — swappable in Settings) |
| ⌘Return | Send, always |
| ⌘↑ | Edit your last message |
| ⇧⌘R | Reply to the newest message |
| ⇧⌘U | Mark as unread |
| ⇧⌘D | Favourite / unfavourite |
| ⌥⌘F | Find in conversation (⌘G / ⇧⌘G to step) |
| ⇧⌘F | Search messages on the server |
| ⌥⌘I | Show conversation details |
| ⇧⌘A | Attach a file |
| ⌘N | New conversation |
| ⌘R | Refresh conversations |
| ⌘/ | Keyboard shortcuts |
| ⌘, | Settings |

## First build

This was written without a macOS SDK, so for most of its life Xcode had never built it. It
does now, clean under Xcode 26.3, which settled the two parts no stand-in could reach:
SwiftData's macros and the Keychain. Where there is no macOS SDK — on Linux, and in CI —
`Tools/uicheck` stands in modules named SwiftUI, AppKit and SwiftData and runs the real
sources through the Swift 6 type checker against them instead. What no compiler settles is
how Liquid Glass actually renders, or anything that needs a real server to answer.
[`docs/MAC_HANDOVER.md`](docs/MAC_HANDOVER.md) is the handover: what has been verified and
how, how to build and sign it, what to do when something goes wrong, and what is worth
your judgement once it runs.

## Documentation

- [`docs/PRODUCT.md`](docs/PRODUCT.md) — what this is, and what it is not
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers, concurrency, data flow
- [`docs/NEXTCLOUD_API.md`](docs/NEXTCLOUD_API.md) — every endpoint and capability relied on, verified against the official docs
- [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) — the plan, and what is done
- [`docs/MAC_HANDOVER.md`](docs/MAC_HANDOVER.md) — **start here on a Mac**: building, signing, signing in, and what to send back when something breaks

## Development against your own server

There are no credentials in this repository and the normal login flow works against any
server. For a development instance on plain HTTP, turn on **Settings → Advanced → Allow
insecure local servers** — it permits HTTP for `localhost` and private-network addresses
only, never for a public host.

## Licence

**MIT** — see [`LICENSE`](LICENSE).

One exception, vendored rather than written here: `.agents/skills/swiftui-pro/` is Paul
Hudson's [SwiftUI Agent Skill](https://github.com/twostraws/SwiftUI-Agent-Skill), which is
MIT and remains his copyright. It is an agent review rule set, not part of the app, and
nothing in the shipping binary comes from it.
