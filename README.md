# Talk for Mac

A native macOS client for [Nextcloud Talk](https://nextcloud.com/talk/), focused on text
chat. Swift and SwiftUI, with AppKit where AppKit behaves better. No Electron, no web view
rendering chat content — it talks to the documented Nextcloud and Talk HTTP APIs directly.

The benchmark is Messages.app: instant launch from cache, native scrolling and selection,
real menu commands, keyboard-first navigation, unread state you can trust.

> **Status:** the chat-first MVP. Calls are deliberately out of scope for v1; the
> architecture leaves room for them.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- A Nextcloud server with the Talk app installed

## Building

```sh
open TalkForMac.xcodeproj      # then ⌘R
```

The project uses Xcode 16+ synchronized folder groups, so new files under `TalkForMac/`
and `Sources/TalkCore/` are picked up automatically — there is no file list to maintain.
`python3 Tools/validate_pbxproj.py` checks the project file's integrity without Xcode, and
runs in CI.

The non-UI half of the app is also a Swift package, so it builds and tests from the
command line — including on Linux, which is what keeps the layering honest:

```sh
swift build
swift test
```

## Signing in

Talk for Mac uses **Login Flow v2**: you enter your server address, approve the app in your
browser, and the app receives a device-specific app password. Your Nextcloud password is
never typed into, or seen by, this app. The app password is stored in the macOS Keychain and
is revoked when you remove the account.

## What works

Accounts (Login Flow v2, Keychain, capability discovery) · conversation list with avatars,
favourites, unread and mention state · chat history with backwards pagination, grouping, day
separators and a new-messages marker · Markdown, mentions, links, files and rich objects ·
sending with optimistic delivery and retry · replies, reactions, editing and deleting where
the server allows it · read markers that only move when you have actually seen a message ·
live updates over Talk's long poll · notifications and Dock badge · local cache, drafts,
offline reading · menu commands and keyboard shortcuts throughout.

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
| ⌘R | Refresh conversations |
| ⌘, | Settings |

## Documentation

- [`docs/PRODUCT.md`](docs/PRODUCT.md) — what this is, and what it is not
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers, concurrency, data flow
- [`docs/NEXTCLOUD_API.md`](docs/NEXTCLOUD_API.md) — every endpoint and capability relied on, verified against the official docs
- [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) — the plan, and what is done

## Development against your own server

There are no credentials in this repository and the normal login flow works against any
server. For a development instance on plain HTTP, turn on **Settings → Advanced → Allow
insecure local servers** — it permits HTTP for `localhost` and private-network addresses
only, never for a public host.
