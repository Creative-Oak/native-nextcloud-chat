# Implementation plan

Living document. Checked off as work lands; new discoveries get appended.

**Decisions (2026-09-13):** name *Talk for Mac*, bundle `dk.creativeoak.TalkForMac`,
deployment target **macOS 26**, persistence **SwiftData**, **macOS CI** on GitHub Actions.

**Build constraint:** the authoring environment is Linux with the Swift 6.1.2 toolchain.
`Sources/TalkCore` + tests are compiled and run on every change. The SwiftUI/AppKit app
target is compiled by CI on a macOS runner. Anything not yet green on CI is marked ⚠.

---

## Phase 0 — Research and docs ✅

- [x] Verify Login Flow v2 against the server developer manual
- [x] Verify conversation API v4: endpoints, params, full field list, `modifiedSince`
- [x] Verify chat API v1: long poll params, headers, send/edit/delete, read markers
- [x] Verify reaction API and required permission bit
- [x] Verify capabilities endpoint shape + full capability list by Talk version
- [x] Verify constants (room types, participant types, permission bits, notification levels)
- [x] Verify rich-object types against `Definitions.php`
- [x] Verify avatar endpoints
- [x] `docs/PRODUCT.md`, `docs/ARCHITECTURE.md`, `docs/NEXTCLOUD_API.md`, `docs/IMPLEMENTATION_PLAN.md`

## Phase 1 — Skeleton, auth, capabilities

- [ ] `Package.swift` (TalkCore + tests), Linux build green
- [ ] `TalkForMac.xcodeproj` with synchronized folders, macOS 26, sandbox + network entitlement
- [ ] Logging (`Log.swift`) with the seven categories and redaction rules
- [ ] `KeychainStore` (+ in-memory `CredentialStore` for tests)
- [ ] `OCSClient`: OCS envelope, typed `OCSError`, Basic auth, `OCS-APIRequest`, retry/backoff,
      `X-Nextcloud-Talk-Hash` observation, HTTPS enforcement with a DEBUG-only escape hatch
- [ ] `AuthenticationService`: Login Flow v2 start + poll + cancel, `/cloud/user` verification,
      app-password deletion on sign-out
- [ ] `CapabilityService` + typed `TalkCapabilities`
- [ ] `AccountStore` — account metadata in SwiftData, secret in Keychain
- [ ] App shell: `WindowGroup` + `Settings` scene, `NavigationSplitView`, window restoration
- [ ] Login UI: server field, validation, browser hand-off, polling state, error states
- [ ] Tests: OCS envelope decode (ok/error/empty-array data), error mapping, capability parsing,
      login-flow state machine against a stubbed transport

## Phase 2 — Conversation list

- [ ] `ConversationDTO` (with the `lastMessage: [] | {}` trap) → `Conversation` domain model
- [ ] `ConversationService`: list, `modifiedSince`, single, favorite, notification level
- [ ] SwiftData `ConversationEntity` + `ConversationRepository`
- [ ] `ConversationSyncEngine`: incremental + periodic full refresh, deletion reconciliation
- [ ] Sidebar UI: avatar, name, one-line preview, relative timestamp, unread dot/count, mention badge
- [ ] Sort: favorites first, then `lastActivity`; Note to Self pinned sensibly
- [ ] `AvatarLoader` actor: memory + disk cache keyed by `avatarVersion`, never blocks a row
- [ ] Fallback avatars: initials, deterministic hue, group/note-to-self/public SF Symbols
- [ ] ⌘F filter, arrow-key navigation, context menu, selection restoration
- [ ] Tests: conversation decode (all room types + missing optional fields), sort order,
      incremental-vs-full merge including removals

## Phase 3 — Reading chat

- [ ] `MessageDTO` → `Message`; parent, reactions, edit metadata, system messages
- [ ] `ChatService.history(...)` with `lookIntoFuture=0`, `setReadMarker=0`
- [ ] SwiftData `MessageEntity` + `MessageRepository` (indexed by token + id)
- [ ] `MessageContentParser` → `[MessageContentNode]`; mentions, links, files, code, rich objects
- [ ] Markdown handling gated on the per-message `markdown` flag
- [ ] Grouping (same sender within 5 min), day separators, "new messages" separator
- [ ] Message row: selectable text, hover actions, reply context, reactions, edited/deleted states
- [ ] Scroll: anchored backwards pagination (no jump), bottom-follow only when already at bottom
- [ ] Tests: message decode fixtures, parser cases incl. hostile display names, grouping, ordering

## Phase 4 — Sending

- [ ] Composer: multiline, auto-grow to a max, ⏎ send / ⇧⏎ newline, ⎋ cancels reply/edit
- [ ] Drafts per conversation, persisted, restored instantly
- [ ] `OutboxCoordinator` + `PendingMessage` states (queued/sending/failed) with retry
- [ ] `referenceId` reconciliation (+ heuristic fallback when the capability is missing)
- [ ] Reply send; ⌘↑ edit last own message; delete with tombstone rendering
- [ ] `ReactionService` + reaction strip + emoji picker, optimistic toggle
- [ ] Tests: reconciliation (both arrival orders), duplicate prevention, failure classification

## Phase 5 — Live behaviour

- [ ] `ActiveChatSyncEngine`: long poll loop, 304 handling, backoff, cancel on switch
- [ ] `SyncCoordinator` lifecycle: launch, conversation change, sleep/wake, network, app active
- [ ] `ReadStateController` with the four-condition rule; mark-as-unread
- [ ] `NotificationController`: UNUserNotificationCenter, notification level respected,
      preview/sound/badge preferences, click → open conversation
- [ ] Dock badge from total unread
- [ ] Reachability + automatic reconnect
- [ ] Tests: poll-loop ordering/dedup, backoff schedule, read-state decision table

## Phase 6 — Polish

- [ ] Full menu bar: App/File/Edit/View/Conversation/Window/Help with real commands
- [ ] ⌘N, ⌘F, ⌘,, ⌘K quick switcher, ⇧⌘U mark unread, ⌘R refresh, ⌘⌫ delete
- [ ] Context menus everywhere; double-click behaviour; ⌘C copy
- [ ] Settings scene: General, Notifications, Accounts, Advanced
- [ ] Empty states, offline banner, quiet inline errors (no modal alert storms)
- [ ] Window/sidebar geometry restoration; reduced motion; dynamic type; VoiceOver labels
- [ ] Performance pass: 10k-message conversation, avatar cache hit rate, re-render audit

## Phase 7 — After the MVP

Attachments (drag & drop, paste screenshot, upload progress, Quick Look) · shared-files
browser · participants inspector (third column) · create conversation · server-side
message search · pins · reminders · voice messages · polls · user status · typing
indicators · per-conversation notification settings · federation polish · calls.

---

## Discovered work (append as found)

- `lastMessage` may be `[]` rather than an object — needs a tolerant decoder. *(found in docs, phase 0)*
- `reactions`/`messageParameters` may be `[]` rather than `{}` — same tolerance needed. *(phase 0)*
- `X-Nextcloud-Talk-Modified-Before` must be echoed as the next `modifiedSince`; using our own
  clock would drift against the server. *(phase 0)*
- 412 from a chat call means the room session died — the fix is re-joining the room, not retrying
  the chat call. *(phase 0)*
