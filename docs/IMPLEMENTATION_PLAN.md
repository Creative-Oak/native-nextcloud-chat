# Implementation plan

Living document. Checked off as work lands; new discoveries get appended.

**Decisions (2026-09-13):** name *kvidr*, bundle `app.kvidr.mac`,
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
- [x] `Kvidr.xcodeproj` with synchronized folders, macOS 26, sandbox + network entitlement
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
- [x] ⌘N create conversation — delivered in phase 7, gated on `canCreateConversations`
- [ ] Performance pass on a real 10k-message conversation (needs a real server)
- [x] First-build pass on macOS: builds clean under Xcode 26.3, no errors and no warnings

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
- [x] Server-side message search (⇧⌘F) through Talk's unified search provider, scoped to
      one conversation or all of them, reaching history older than the local cache
- [ ] Pins, reminders, voice messages, polls (rendered, not yet interactive)
- [ ] Typing indicators and user-status editing (both need signaling or the status API)
- [ ] Calls — deliberately out of scope; see ARCHITECTURE.md § Room for calls

---

## Known gaps

- **Mac only.** It was written on Linux, and for a while `Kvidr/` was type-checked there
  against stand-in SwiftUI and AppKit modules. That harness and its CI job are gone
  (2026-09-16): CI builds the app with Xcode and runs the `TalkCore` tests on macOS, and
  `Tools/check_core_layering.sh` keeps UI frameworks out of `Sources/TalkCore`. What no build
  settles is how Liquid Glass renders, and anything that is a runtime behaviour rather than a
  type. See docs/MAC_HANDOVER.md.
- **Signing needs Keychain Sharing.** The app password and the cache keys live in the
  data-protection keychain, which a Mac app can only use with a keychain access group. Xcode's
  automatic signing handles it for development; a Developer ID build needs a provisioning
  profile with the same capability, or sign-in fails.

## Backlog — deferred on purpose

Things decided against for now, with the reason, so the decision can be revisited rather than
rediscovered. Not bugs and not gaps: each of these works as built.

- **Photos go up as HEIC, unconverted.** Nextcloud renders previews server-side, so a
  recipient *sees* the picture whatever they are on — but someone on Windows or an older
  Android who downloads the original may get a file they cannot open. Converting costs a
  generation of quality and a re-encode, so the original wins by default. The escape is a
  setting, and unlike the contacts one it needs real work behind it: an ImageIO re-encode on
  the way out, not a toggle. Worth doing if anyone reports an unopenable photo.
- **The message cache grows without bound.** Rows go when an account signs out, a conversation
  disappears, or a message is deleted — but nothing prunes by age or count, and paging back
  through history deepens the cache permanently. Fine at chat-message sizes; unbounded by
  omission rather than by decision.
- **The models live in the app target.** `ChatModel`, `ConversationListModel`,
  `InspectorModel`, `ConversationDraft` and `PollStore` are `@Observable` and nearly
  platform-free, but they sit in `Kvidr/` beside AppKit. Extracting them into a shared layer is
  low-risk and useful on its own — and it is the difference between "could this be an iOS app?"
  being a question and being an estimate. `TalkCore` itself is already 7,400 lines with no
  AppKit in it at all.
- **Image Playground and Genmoji.** Apple APIs that produce an image, which would feed the
  attachment tray like any other. Cheap once staging exists, gated on Apple Intelligence, and
  they only make more pictures — so they were cut from the attachments design rather than
  built.
- **Poll counts are not live.** Nobody else's vote says anything on the wire and this project
  does not use the signaling API (§ 9), so a card reads on appear and after its own actions.
  The alternative is a timer per visible poll, which is worse.
- **The recipient dropdown is inset by a fixed 44pt**, which is where the cursor sits before
  any chips are in the way. Add two recipients and the cursor moves right while the panel does
  not. Measuring the caret would fix it.
- **A very wide panorama becomes a thin strip.** Images cap at 420×520, so 3:1 lands at
  420×140. It is honestly that shape; letting width exceed the cap for extreme ratios would be
  the fix if panoramas turn out to be common.

## Security audit follow-up — done 2026-09-16

The audit (PR #1) closed with three items named as open. All three are fixed, and testing the
fixes on a real Mac turned up four more.

- **The cache is encrypted.** Messages, conversations, drafts and account details are sealed
  with AES-GCM under a per-account key in the data-protection keychain; only ids, tokens,
  timestamps and counts stay readable. Signing out destroys the key, so what SQLite keeps in
  the file's free pages, or a backup kept, can't be opened. A plaintext cache is rebuilt into
  a new file at launch rather than encrypted in place — in place, the old rows stay readable
  in the free pages, which a test confirms. Accounts and drafts are carried; the rest resyncs.
  *(`279578d`)* This replaces the backlog item that asked whether FileVault was enough.
- **Cache keys can't collide.** Keys were their parts joined with `|`, and an account id
  already contains one, so two different rows could share a unique key and overwrite each
  other. Parts are escaped now. *(`edee9e7`)*
- **A wedged network mount costs one upload, not the app.** Nothing touches an attachment on
  the main actor or the upload actor: the file is checked off-actor under a 10-second deadline,
  and read by a thread of the app's own into a stream (`FileBodyPump`), with a watchdog that
  fails a read stuck past 30 seconds. Verified against a paused SMB share: other uploads carry
  on and the stuck one fails with "The disk that file is on isn't answering".
  *(`235c1b7`, `78900f8`, `4d00978`, `6e9a97d`)*
- **Found on the way: new sign-ins were broken by the audit itself.** It moved credentials to
  the data-protection keychain without the keychain access group a Mac app needs to use it.
  Existing sign-ins survived only through the legacy read fallback; a new one failed to store
  its app password and said "The server sent something unexpected". *(`b48bb9e`)*
- **Found on the way: the upload tray's buttons did nothing.** Interactive glass on each row
  took the click, so a failed upload could never be retried or cleared. *(`5aa7350`)*
- **Found on the way: switching conversations emptied the upload tray.** Each visit built a
  fresh queue while the old upload carried on unseen. Queues now live for the session.
  *(`eb8372e`)*
- **Found on the way: attachment failures all read "The server sent something unexpected".**
  They were sent as `unexpectedResponse`, whose message is fixed. They have their own errors
  now, including one for a file that has since disappeared. *(`4d00978`, `5aa7350`)*

## Discovered work (append as found)

- `uploadTask(with:fromFile:)` reads the file on `URLSession`'s own threads, so a read that
  never returns stalls every transfer in the process. And a named pipe is no stand-in for a
  stuck file there: `URLSession` takes it for an empty file and never reads it. *(2026-09-16)*
- SQLite keeps deleted and overwritten rows in the file's free pages and the write-ahead log.
  Encrypting a cache in place, or deleting rows on sign-out, leaves the old content on disk.
  *(2026-09-16)*
- `glassEffect(.regular.interactive())` on a container swallows clicks meant for the buttons
  inside it. Interactive glass belongs on a control, not on a row holding controls.
  *(2026-09-16)*
- A Mac app without `keychain-access-groups` gets `errSecMissingEntitlement` (-34018) from the
  data-protection keychain on every call. *(2026-09-16)*

- Unified search types `attributes` as an array of strings, but the server builds it as a
  PHP associative array — so it arrives as an object, and it is the only machine-readable
  part of a search hit. *(phase 7)*
- A `@ViewBuilder` method that renders nested content cannot return `some View` and recurse:
  the opaque type ends up defined in terms of itself. Quoted blocks needed a nominal view.
  *(found by the stub type-check)*
- An `EnvironmentKey`'s `defaultValue` is a `static let`, so a bare closure type fails Swift
  6's Sendable rule; the environment's action closures have to be `@MainActor`.
  *(found by the stub type-check)*
- An actor-isolated method cannot satisfy a nonisolated protocol requirement, so a protocol
  whose only real implementation is an actor has to declare the method `async`.
  *(found by the stub type-check)*

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
