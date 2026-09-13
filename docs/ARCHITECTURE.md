# Architecture

## Layers

```
            ┌───────────────────────────────────────────────┐
  UI        │ SwiftUI views + AppKit representables         │  TalkForMac/
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
3. **No SwiftUI/AppKit import inside `Sources/TalkCore`** (it must keep compiling on
   Linux so the test suite can run anywhere).
4. **Nothing blocks the main actor.** Networking and persistence are actors.
5. **Secrets live only in the Keychain.** Never `UserDefaults`, never SwiftData, never logs.

## Repository layout

```
Package.swift                  swift build / swift test — core + tests, runs on Linux & macOS
Sources/TalkCore/              Foundation-only. The whole non-UI application.
  Models/                      Domain models (Account, Conversation, Message, …)
  Networking/                  OCSClient, OCSError, endpoints, DTOs
  Services/                    Authentication, Capability, Conversation, Chat, Reaction, Participant, Avatar
  Sync/                        SyncCoordinator + engines + outbox
  Persistence/                 SwiftData models, repositories, store actor   (#if canImport(SwiftData))
  Security/                    KeychainStore                                  (#if canImport(Security))
  Rendering/                   MessageContentParser → [MessageContentNode]
  Support/                     Logging, clocks, backoff, reachability
Tests/TalkCoreTests/           Unit tests + sanitized JSON fixtures
TalkForMac/                    The macOS app target (SwiftUI + AppKit + notifications)
  App/ Features/ UI/ Notifications/ Resources/
TalkForMac.xcodeproj           Xcode 26 project, synchronized folders
docs/
```

### The one-module trick

`TalkForMac.xcodeproj` compiles `Sources/TalkCore/**` **directly into the app target**
via a synchronized folder group, rather than linking the package as a library. That is
why:

> **No file in this repository ever writes `import TalkCore`.**

In the Xcode build everything is one module (`TalkForMac`). In the SwiftPM build,
`TalkCore` is its own module and the tests use `@testable import TalkCore`. The SwiftPM
build is what enforces the layering: if a core file ever reaches for a UI type, or
imports SwiftUI, `swift build` fails on Linux immediately.

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

Two seams exist so calls can be added without surgery:

1. `LiveUpdateTransport` — protocol with a long-polling implementation today. A
   signaling-based implementation can replace it per-conversation without touching
   engines or UI.
2. `CallCapability` is already parsed and `hasCall` / `callFlag` / `participantFlags`
   are already modelled, so the sidebar and header can surface an ongoing call before
   any call code exists.

## Mentions

Detection (`@…` under the caret) and the wire syntax (`mentionId` after the `@`, quoted when
it contains a space or a slash — straight from the Talk docs) live in `MentionComposer` in
the core, with tests. The composer only does the popover and the keyboard handling: while
the suggestion list is open it takes Return, Tab, Escape and the arrow keys, so Return picks
a name instead of sending a half-typed message.

`@all` is filtered out when the server's `mentionPermissions` restricts it to moderators.

## Verification, without a Mac

This repository was largely written on Linux, which has no macOS SDK. Three things stand in
for the compiler on the UI layer:

1. `swift build` / `swift test` compile and run **all** of `Sources/TalkCore` — which is why
   as much logic as possible lives there, including transcript grouping, previews, relative
   timestamps and mention syntax, none of which are inherently UI.
2. `swiftc -parse` over `TalkForMac/**` catches syntax errors.
3. `Tools/validate_pbxproj.py` parses the hand-written Xcode project as an OpenStep plist
   and checks for dangling references and malformed targets, so the worst failure —
   "the project won't open" — is caught without Xcode.

The macOS CI job is what actually type-checks the SwiftUI layer.

## Logging

`os.Logger` with subsystem `dk.creativeoak.TalkForMac` and categories
`auth`, `api`, `sync`, `chat`, `persistence`, `notification`, `ui`.
`Authorization` headers and app passwords are never logged in any build. Message bodies
are `private` in the log format and only materialize under the developer-mode flag.
