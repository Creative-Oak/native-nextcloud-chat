# Talk for Mac — Product Definition

**One line:** Nextcloud Talk, but as a genuinely excellent Mac messaging app.

## North star

> If Apple built a lightweight native Mac client for Nextcloud Talk, what would it feel like?

Nextcloud is the *backend and protocol*. Messages.app is the *UX benchmark*. Where the
two disagree, we follow Apple's platform conventions, not Talk's web UI.

## What this is

A real macOS application (bundle id `dk.creativeoak.TalkForMac`, deployment target macOS 26) written in Swift and SwiftUI (with AppKit where AppKit is
genuinely better), talking directly to the documented Nextcloud and Nextcloud Talk
HTTP APIs.

## What this explicitly is not

- Not Electron.
- Not a wrapper around the Talk web app.
- Not a `WKWebView` rendering chat content. No remote HTML, no remote JavaScript,
  ever, anywhere in the message pipeline.
- Not a port of Talk's web sidebar/dashboard layout.
- Not a Slack/Discord/Teams visual clone.

## Qualities we are optimizing for

These are acceptance criteria, not aspirations:

| Quality | What it means concretely |
| --- | --- |
| Instant | Cached conversation list is on screen before the first network call returns. Opening a cached conversation shows messages in the same runloop turn. |
| Native | Real menu bar commands, real context menus, real text selection, real keyboard navigation, real window restoration. |
| Trustworthy unread | A message is never marked read because it was *downloaded*. Only because it was *selected, in a key window, and presented*. |
| Never janky | Scrolling a 10 000-message conversation stays smooth. One incoming message re-renders one row, not the conversation. |
| Calm | Errors are quiet inline state, not modal alerts. Loading states are subtle. No spinners on launch. |
| Keyboard-first | The whole MVP is drivable without touching the mouse. |
| Offline-tolerant | No network means a slightly dimmer app, not an error page. |

## MVP — definition of done

The user can:

1. Clone the repo and open it in Xcode.
2. Build and launch.
3. Enter a Nextcloud URL, authenticate in the browser (Login Flow v2), return authenticated.
4. See their Talk conversations, sorted sensibly, with avatars and unread state.
5. Click a conversation and see cached history immediately, then live history.
6. Receive new messages without refreshing (long poll).
7. Send, reply, react, edit, delete (where the server allows it).
8. See accurate read/unread state and mention indicators.
9. Get macOS notifications and a Dock badge for messages in inactive conversations.
10. Quit, relaunch, and find cached conversations, cached messages, drafts, selection,
    and window geometry intact.
11. Do all of the above from the keyboard.

## Scope ladder

**MVP (phases 1–6):** accounts, conversations, chat history, sending, replies,
reactions, edit/delete, read state, mentions, conversation filtering, notifications,
local cache, drafts, keyboard, native UI.

**Phase 7, shipped in 1.0:** attachments and drag-and-drop upload, inline images and an
in-app viewer, shared-file browser, participants inspector, conversation creation and
moderator settings, per-conversation notification settings, find in conversation, and
server-side message search across the whole history.

**Phase 7, still open:** pins, reminders, voice messages, interactive polls, user-status
editing, typing indicators. The last two need Talk's signaling API; polls and voice
messages are shown but not yet answered or played.

**Explicitly out of scope for v1:** calls, audio, video, screen sharing, signaling.
The architecture leaves room for them (see `ARCHITECTURE.md` § Room for calls) but
nothing in the MVP depends on the signaling stack.

## Visual direction

SF Symbols, system fonts, semantic colors, subtle separators, generous spacing,
minimal chrome. Vibrancy only in the sidebar, where macOS itself uses it. No giant
rounded cards, no dashboards, no gradients, no oversized headings. Conversation
content gets the visual space.
