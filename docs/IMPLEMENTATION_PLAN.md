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

## Phase 1 — Skeleton, auth, capabilities ✅

- [x] `Package.swift` (TalkCore + tests), Linux build green
- [x] `TalkForMac.xcodeproj` with synchronized folders, macOS 26, sandbox + network entitlement
- [x] Logging (`Log.swift`) with the seven categories and redaction rules
- [x] `KeychainStore` (+ in-memory `CredentialStore` for tests)
- [x] `OCSClient`: OCS envelope, typed `TalkError`, Basic auth, `OCS-APIRequest`,
      `X-Nextcloud-Talk-Hash` observation, HTTPS enforcement with a developer-only escape hatch
- [x] `AuthenticationService`: Login Flow v2 start + poll + cancel, `/cloud/user` verification,
      app-password revocation on sign-out
- [x] `CapabilityService` + typed `TalkCapabilities`
- [x] Account metadata in SwiftData, secret in Keychain
- [x] App shell: `WindowGroup` + `Settings` scene, `NavigationSplitView`
- [x] Login UI: server field, validation, browser hand-off, polling state, error states
- [x] Tests: OCS envelope decode (ok/error/empty-array data), error mapping, capability parsing,
      login-flow state machine against a stubbed transport
- [ ] ⚠ Verified only by CI/Xcode: the SwiftUI layer has not been compiled locally

## Phase 2 — Conversation list ✅

- [x] `ConversationDTO` (with the `lastMessage: [] | {}` trap) → `Conversation` domain model
- [x] `ConversationService`: list, `modifiedSince`, single, favourite, notification level
- [x] SwiftData `CachedConversation` + `TalkStore`
- [x] `ConversationSyncEngine`: incremental + periodic full refresh, deletion reconciliation
- [x] Sidebar UI: avatar, name, one-line preview, relative timestamp, unread dot/count, mention badge
- [x] Sort: favourites first, then `lastActivity`
- [x] `AvatarLoader`: memory + actor-backed disk cache keyed by `avatarVersion`, never blocks a row
- [x] Fallback avatars: initials, deterministic hue, group/note-to-self/public SF Symbols
- [x] ⌘F filter, arrow-key navigation, context menu, selection restoration
- [x] Tests: conversation decode (all room types + missing optional fields), sort order,
      incremental-vs-full merge including removals

## Phase 3 — Reading chat ✅

- [x] `MessageDTO` → `Message`; parent, reactions, edit metadata, system messages
- [x] `ChatService.history(...)` with `lookIntoFuture=0`, `setReadMarker=0`
- [x] SwiftData `CachedMessage` (indexed by account + token + id)
- [x] `MessageContentParser` → blocks and inline nodes; mentions, links, files, code, rich objects
- [x] Markdown handling gated on the per-message `markdown` flag
- [x] Grouping (same sender within 5 min), day separators, "new messages" separator
- [x] Message row: selectable text, hover actions, reply context, reactions, edited/deleted states
- [x] Scroll: backwards pagination near the top, bottom-follow only when already at bottom
- [x] Tests: message decode fixtures, parser cases incl. hostile display names, grouping, ordering

## Phase 4 — Sending ✅

- [x] Composer: multiline, auto-grow to a max, ⏎ send / ⇧⏎ newline, ⎋ cancels reply/edit
- [x] Drafts per conversation, persisted (debounced), restored instantly
- [x] Optimistic send with queued/sending/failed states and retry
- [x] `referenceId` reconciliation (+ bounded heuristic fallback when the capability is missing)
- [x] Reply send; ⌘↑ edit last own message; delete with tombstone rendering
- [x] `ReactionService` + reaction strip + emoji picker, optimistic toggle
- [x] Tests: reconciliation (both arrival orders), duplicate prevention, failure handling

## Phase 5 — Live behaviour ✅

- [x] `ActiveChatSyncEngine`: long poll loop, 304 handling, backoff, cancel on switch, 412 re-join
- [x] Lifecycle wiring in `AppModel`: launch, conversation change, network, app active
- [x] `ReadStatePolicy` with the four-condition rule; mark-as-unread
- [x] `NotificationController`: UNUserNotificationCenter, notification level respected,
      preview/sound/badge preferences, click → open conversation
- [x] Dock badge from total unread
- [x] Reachability + automatic reconnect
- [x] Tests: poll-loop behaviour, backoff schedule, read-state decision table

## Phase 6 — Polish (in progress)

- [x] Menu bar with real commands, including a Conversation menu
- [x] ⌘F, ⇧⌘K, ⌥⌘↑/↓, ⇧⌘], ⇧⌘U, ⇧⌘D, ⌘R, ⌘↑, ⇧⌘R
- [x] Context menus on messages and conversations; ⌘C copy
- [x] Settings scene: General, Notifications, Accounts, Advanced
- [x] Empty states, offline indicator, quiet inline errors (no modal alert storms)
- [x] Reduced-motion respected; VoiceOver labels on sidebar rows and avatars
- [x] ⌘K quick switcher
- [x] Mention autocomplete, with the `@"quoted id"` syntax taken from the docs
- [x] Window frame restoration; quit-safe drafts; double-click a conversation
- [x] Talk-hash capability refresh wired end to end
- [x] Tooling that stands in for the compiler: `Tools/preflight.sh`
- [ ] ⌘N create conversation (phase 7 — the menu item exists and is disabled)
- [ ] Performance pass on a real 10k-message conversation (needs a real server)
- [ ] First-build pass on macOS: the SwiftUI layer has never been type-checked

## Phase 7 — Beyond the MVP (largely done)

- [x] Liquid Glass design pass (macOS 26), applied to the floating layer only
- [x] Attachments: drag & drop, ⇧⌘A, paste an image, real byte progress, numbered names
      instead of overwriting
- [x] Inline image previews + an in-app viewer with save and open-in-Nextcloud
- [x] Third-column inspector: info, participants (invite/remove), shared files
- [x] ⌘N create conversation (direct / group / open) with Nextcloud people search
- [x] Conversation settings: rename, description, read-only, message expiration, link
      access, password, leave, delete
- [x] Find in conversation (⌥⌘F), searching rendered text rather than raw protocol text
- [x] Sidebar sections, including an archive that stays searchable
- [x] Who-reacted popover
- [x] Keyboard shortcuts window (⌘/)
- [ ] Server-side message search (Talk's unified search provider) for history older than
      the local cache
- [ ] Pins, reminders, voice messages, polls (rendered, not yet interactive)
- [ ] Typing indicators and user-status editing (both need signaling or the status API)
- [ ] Calls — deliberately out of scope; see ARCHITECTURE.md § Room for calls

---

## Known gaps

- **The SwiftUI/AppKit layer has not been type-checked.** It was written on Linux, where no
  macOS SDK exists. Everything in `Sources/TalkCore` is built and tested on every change
  (178 tests); `TalkForMac/` is checked by `Tools/preflight.sh` — syntax, framework imports,
  duplicate declarations, and the Xcode project's integrity — and type-checked only by the
  macOS CI job. Expect a first-build error pass; see docs/FIRST_BUILD.md.
- **Not yet run against a real server.** Every request shape is verified against the
  documentation and against fixtures, but no live Nextcloud has answered one of them.

## Discovered work (append as found)

- `lastMessage` may be `[]` rather than an object — needs a tolerant decoder. *(found in docs, phase 0)*
- `reactions`/`messageParameters` may be `[]` rather than `{}` — same tolerance needed. *(phase 0)*
- `X-Nextcloud-Talk-Modified-Before` must be echoed as the next `modifiedSince`; using our own
  clock would drift against the server. *(phase 0)*
- 412 from a chat call means the room session died — the fix is re-joining the room, not retrying
  the chat call. *(phase 0)*
- Re-joining after a 412 must use `force=false`, or the user's own web/phone session gets
  kicked out from under them. *(phase 5)*
- `AsyncStream` continuations must be finished on **every** exit path of a sync loop, not just
  the normal one — the 401 test caught a consumer task that leaked forever. *(phase 5)*
- Merging a batch message-by-message is O(n²) because of re-indexing; batches must sort once.
  Found by the 10k-message test taking 34s. *(phase 4)*
- `NSImage` is not `Sendable`, so `AvatarLoader` cannot be an actor that returns images. It is
  main-actor with an actor-backed disk cache that only moves `Data`. *(phase 2)*
- The Nextcloud/Talk OpenAPI descriptions are a better source than the prose docs where the
  two disagree: they settled the shared-items response shape (a map, not an array), the
  `status`-is-sometimes-a-string quirk in core autocomplete, and the fact that adding a
  participant POSTs to `/participants` while removing one DELETEs `/attendees`. *(phase 7)*
- `sessionIds` contains the literal string `"0"` for a participant with no session, so a
  non-empty array does not mean "online". *(phase 7)*
- Transcript grouping, previews and relative timestamps started life in the app target where
  they could not be tested; moved into `TalkCore` and covered. The move immediately caught an
  invalid `Date.FormatStyle` symbol. *(phase 6)*
- Four SwiftUI files used AppKit types with only `import SwiftUI` — invisible on Linux, four
  instant errors on a Mac. `Tools/check_imports.py` now catches that family. *(phase 6)*
- `ChatModel.deactivate()` scheduled the shared engine's stop in a detached Task, so
  switching conversations could stop the engine *after* the next one started it. *(phase 6)*
- The scroll-to-bottom button only flipped the "am I at the bottom" flag without scrolling,
  and the initial scroll ran before the cached rows existed. *(phase 6)*
- Accepting a mention re-detected the mention it had just completed and reopened the
  popover; the rewrite has to be atomic with respect to detection. *(phase 6)*
