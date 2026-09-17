# Architecture

## Layers

```
            ┌───────────────────────────────────────────────┐
  UI        │ SwiftUI views + AppKit representables         │  Kvidr/
            │ small @Observable feature models              │
            └───────────────▲───────────────────────────────┘
                            │ domain models, never DTOs
            ┌───────────────┴───────────────────────────────┐
  Sync      │ SyncCoordinator · ConversationSyncEngine       │  Sources/TalkCore/Sync
            │ ActiveChatSyncEngine · OutboxCoordinator       │
            └───────▲───────────────────────▲───────────────┘
                    │                       │
            ┌───────┴────────┐      ┌───────┴───────────────┐
  Services  │ Talk services  │      │ Repositories           │  Core/Services, Core/Persistence
            │ (API layer)    │      │ (SwiftData-backed)     │
            └───────▲────────┘      └───────▲───────────────┘
                    │                       │
            ┌───────┴────────┐      ┌───────┴───────────────┐
  Infra     │ OCSClient      │      │ ModelContainer         │
            │ URLSession     │      │ Keychain               │
            └────────────────┘      └───────────────────────┘
```

Hard rules:

1. **No `URLSession` outside `Sources/TalkCore/Networking`.**
2. **No OCS DTO ever reaches a view.** Services return domain models.
3. **No SwiftUI/AppKit import inside `Sources/TalkCore`** — `Tools/check_core_layering.sh`
   enforces it, in CI and in preflight.
4. **Nothing blocks the main actor.** Networking and persistence are actors.
5. **Secrets live only in the Keychain.** Never `UserDefaults`, never SwiftData, never logs.

## Repository layout

```
Package.swift                  swift build / swift test — core + tests
Sources/TalkCore/              Foundation-only. The whole non-UI application.
  Models/                      Domain models (Account, Conversation, Message, …)
  Networking/                  OCSClient, OCSError, endpoints, DTOs
  Services/                    Authentication, Capability, Conversation, Chat, Reaction, Participant, Avatar
  Sync/                        SyncCoordinator + engines + outbox
  Persistence/                 SwiftData models, repositories, store actor   (#if canImport(SwiftData))
  Security/                    KeychainStore                                  (#if canImport(Security))
  Rendering/                   MessageContentParser → [MessageContentNode]
  Intelligence/                DateExpressionScanner, SuggestionScanner — no model needed
  Support/                     Logging, clocks, backoff, reachability
Tests/TalkCoreTests/           Unit tests + sanitized JSON fixtures
Kvidr/                    The macOS app target (SwiftUI + AppKit + notifications)
  App/ Features/ UI/ Notifications/ Resources/
  Features/Intelligence/       The only place FoundationModels is imported
Kvidr.xcodeproj           Xcode 26 project, synchronized folders
docs/
```

### Services

Per account, all actors, all constructed in `Session`:

| Service | Covers |
| --- | --- |
| `AuthenticationService` | Login Flow v2, verification, revocation |
| `CapabilityService` | Capability fetch + Talk-hash invalidation |
| `ConversationService` | Room list, creation, rename/description/read-only/expiration/password, join/leave |
| `ChatService` | History, long poll, send/edit/delete, read markers, mention suggestions |
| `ReactionService` | Add/remove/list, and who reacted |
| `ParticipantService` | List, invite, remove, leave |
| `DirectoryService` | Nextcloud core people/group search |
| `SharedItemsService` | The inspector's Files tab |
| `AttachmentService` | WebDAV upload, Talk share, previews, download |

### The one-module trick

`Kvidr.xcodeproj` compiles `Sources/TalkCore/**` **directly into the app target**
via a synchronized folder group, rather than linking the package as a library. That is
why:

> **No file in this repository ever writes `import TalkCore`.**

In the Xcode build everything is one module (`Kvidr`). In the SwiftPM build,
`TalkCore` is its own module and the tests use `@testable import TalkCore`. The SwiftPM
package is what keeps the layering visible: a core file that reaches for a UI type has to
import a UI framework to do it, and `Tools/check_core_layering.sh` refuses that import.

Consequence: core types stay `internal` (not `public`). `@testable import` gives the
tests access, and the app target doesn't need the access level at all.

## Concurrency model

- `OCSClient` — `actor`. Owns one `URLSession`; one more for long polling with a
  longer timeout.
- Repositories — SwiftData `@ModelActor`s, so all persistence happens off the main actor.
- Sync engines — `actor`s driving structured `Task`s, cancelled deterministically on
  conversation change, sleep/wake, and network loss.
- Feature models (`ConversationListModel`, `ChatModel`, `ComposerModel`) — `@Observable`
  `@MainActor` classes. Small, one per feature, injected through the SwiftUI environment.
- There is **no** god object. `AppState` owns the account, the service container and the
  sync coordinator, and nothing else.

Swift 6 strict concurrency is on. Domain models are `Sendable` value types.

## Data flow for one incoming message

```
long poll returns ──► ChatService decodes DTO ──► MessageMapper → Message (domain)
   └─► MessageRepository.upsert (ModelActor, off main)
         └─► ChatModel.apply(diff)  (main actor, mutates ONE element of an array)
               └─► SwiftUI re-renders ONE row (stable .id = message.id)
```

Identity discipline: rows are identified by the **server message id**, or the local
`clientId` for not-yet-acknowledged optimistic messages. Nothing keys off array indices,
so an insert at the top never re-renders the bottom.

## Optimistic send

```
user hits ⏎
  └─ OutboxCoordinator.enqueue(text, replyTo)          referenceId = sha256(uuid)
       ├─ insert PendingMessage (state .sending) → appears instantly
       ├─ POST /chat/{token}
       │    ├─ 201 → reconcile(referenceId) → replace pending with server message
       │    ├─ 4xx permanent → state .failed(reason), retry affordance
       │    └─ network → state .queued, retried on reachability
       └─ long poll may deliver the same message first → dedup by referenceId
```

The reconciler is pure and tested (`MessageReconcilerTests`): given a pending set and an
incoming batch, it returns the resulting ordered list with no duplicates, regardless of
which arrives first.

## Read state

`ReadStateController` owns the rule. A message may only be marked read when **all** of:

- its conversation is the selected one,
- the window is key **and** the app is active,
- the message is at or above the scroll viewport bottom,
- the user has not explicitly marked the conversation unread.

Therefore every background chat fetch sends `setReadMarker=0` and
`markNotificationsAsRead=0`, and the read marker is pushed explicitly by the controller.
Downloading a message never marks it read.

## Capability gating

`TalkCapabilities` is a value type built once per account per Talk-hash. Every
feature-conditional call site reads a named property (`capabilities.canEditMessages`),
never a version number. Absent capability → the affordance is hidden (not disabled and
not failing at runtime). Unknown capability strings are retained so nothing is lost.

## Message rendering pipeline

```
Message.message + messageParameters
        │
        ▼  MessageContentParser  (pure, Foundation-only, heavily tested)
[MessageContentNode]   .text(String, MarkdownInline?) | .mention(Mention)
                       .link(URL, String) | .file(FileRef) | .code(String, lang)
                       .quote(...) | .richObject(RichObject) | .unsupported(String)
        │
        ▼  SwiftUI
AttributedString for inline runs; dedicated views for blocks
```

Rules: placeholders are substituted **structurally**, not by string interpolation, so a
display name containing `{mention-user1}` cannot forge a mention. Markdown is parsed
only when the server sets `markdown: true`, using Apple's `AttributedString(markdown:)`
with `.inlineOnlyPreservingWhitespace` for inline runs and our own block splitter for
code fences, quotes and lists. **No HTML is ever parsed or rendered.**

## Offline

`Reachability` (NWPathMonitor) drives a three-state `ConnectionState`
(`online`, `offline`, `reconnecting`). Offline means: engines park, the outbox holds,
a thin status line appears above the conversation list, and *nothing else changes*.
Cached data stays on screen. On recovery, engines restart with a full refresh.

## Room for calls (later, not now)

No speculative abstraction has been built for calls — there is no `CallTransport` protocol
with one implementation, because that is architecture theatre until there is a second
implementation. What exists instead is a genuine seam and a genuine head start:

1. **`ActiveChatSyncEngine` is the seam.** It is the only thing that knows *how* live
   updates arrive. It exposes `AsyncStream<ChatSyncEvent>` and nothing above it knows about
   long polling. A signaling-based implementation replaces the inside of that one actor;
   `ChatModel` and the views do not change. That is as much decoupling as is useful, and it
   cost nothing to have.
2. **The call fields are already modelled.** `hasCall`, `callFlag`, `callStartTime`,
   `canStartCall` and `participantType` are parsed and carried through to `Conversation`, so
   the sidebar and the conversation header can show "call in progress" before a single line
   of call code exists.

What a call implementation would have to add: the signaling stack (internal or external
HPB), WebRTC, and a call UI. None of the MVP depends on any of it.

## Liquid Glass

macOS 26's `glassEffect(_:in:)` is powerful enough to make a mess with, so the material is
not applied ad hoc. `UI/Design/GlassStyle.swift` defines four *roles* and every call site
asks for a role rather than for a material:

| Role | Used by |
| --- | --- |
| `.floating` | Controls hovering over the transcript: message actions, the scroll-to-bottom button, the offline pill, the upload rows |
| `.panel` | Transient surfaces over content: quick switcher, mention list, emoji picker, find bar, image viewer chrome, login card |
| `.chip` / `.selectedChip` | Reaction pills and the people chips in New Conversation |

Two deliberate decisions:

1. **The transcript is not glass.** Apple's guidance is that Liquid Glass belongs to the
   layer *above* content, and a chat transcript is content. Messages, the sidebar rows and
   message text stay ordinary opaque surfaces; if everything is glass, nothing reads as
   floating.
2. **Reaction pills share a `GlassEffectContainer`.** With a container spacing wider than the
   gap between pills, neighbouring reactions merge into one glass shape and a new reaction
   flows out of the pill beside it rather than popping into place. This is the one place the
   material does something no other material could.

APIs used, all verified against Apple's documentation rather than memory: `glassEffect(_:in:)`,
`Glass.regular/.tint(_:)/.interactive(_:)`, `GlassEffectContainer(spacing:)`,
`glassEffectID(_:in:)`, `.buttonStyle(.glass)` and `.glassProminent`, `ToolbarSpacer`.

## Mentions

Detection (`@…` under the caret) and the wire syntax (`mentionId` after the `@`, quoted when
it contains a space or a slash — straight from the Talk docs) live in `MentionComposer` in
the core, with tests. The composer only does the popover and the keyboard handling: while
the suggestion list is open it takes Return, Tab, Escape and the arrow keys, so Return picks
a name instead of sending a half-typed message.

`@all` is filtered out when the server's `mentionPermissions` restricts it to moderators.

## Verification

`./Tools/preflight.sh` runs what CI runs: the layering check above, `swift test` over all of
`Sources/TalkCore` — which is why as much logic as possible lives there, including transcript
grouping, previews, relative timestamps and mention syntax, none of which are inherently UI —
and an `xcodebuild` of the app.

## Logging

`os.Logger` with subsystem `app.kvidr.mac` and categories
`auth`, `api`, `sync`, `chat`, `persistence`, `notification`, `ui`.
`Authorization` headers and app passwords are never logged in any build. Message bodies
are `private` in the log format and only materialize under the developer-mode flag.
