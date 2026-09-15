# New Message, the way Messages does it — design

*15 September 2026. Replaces the New Conversation sheet.*

⌘N stops opening a dialog. It puts a draft conversation at the top of the sidebar with a
**To:** field, and the people you add decide what the conversation turns out to be. Nothing
exists on the server until you send.

## 0. What Talk allows

Checked against `spreed/lib/Controller/RoomController.php`, because three of its behaviours
decide the shape of this:

- **One-to-one creation is idempotent.** `createOneToOneRoom` looks for an existing room
  first and answers **200** with it; only when there is none does it create one and answer
  **201**. So "New Message → Heine" lands in the conversation you already have with Heine,
  which is exactly what Messages does and costs us nothing.
- **Everyone can be invited at once** through the `participants` array (`users`, `groups`,
  `teams`), rather than the legacy single `invite` plus follow-up invitations.
- **A group must be named.** With no `roomName` and no legacy `invite`, Talk falls back to
  `prepareConversationName('---')` — an unnamed group is literally called `---`.

## 1. The draft, and how the sidebar holds it

Selection is a `String?` token everywhere: `List(selection:)`, `AppModel.selectedToken`, and
the `didSet` that opens a conversation. A draft has no token, so it gets a reserved one:

```swift
/// The draft's stand-in. Reserved: a Talk token is 8 characters of [a-z0-9], so this can
/// never collide with a real one.
static let draftToken = "#draft"
```

Every part of the selection machinery — arrow keys, clicking, restoring the last selection —
then keeps working untouched, and only the places that turn a token into a conversation need
to know a draft exists.

`AppModel` gains one optional:

```swift
/// The unsent conversation, if there is one. In memory on purpose: an unaddressed, unsent
/// conversation is not data yet.
private(set) var draft: ConversationDraft?
```

`ConversationDraft` is `@Observable` and holds the recipients, the `isOpen` toggle and the
typed text. ⌘N makes one if there isn't one and selects it; if there already is one it
selects and focuses it, so a second ⌘N never makes a second row.

The sidebar draws it pinned above the conversations, labelled **New Message** until it has
recipients and then by their names, with an × that clears the draft and restores the previous
selection. The detail pane branches on the same token: the draft gets a To: field above and
the ordinary composer below; everything else gets today's `ChatView`.

`lastSelectedToken` needs one guard, or a relaunch restores a draft that no longer exists.

## 2. The To: field

Little of this is new. `NewConversationModel` already owns the people search — the debounce,
`results`, `selected`, `toggle` — against `GET /core/autocomplete/get` with `itemType=call`
and `itemId=new`. It survives the sheet's deletion, loses `kind` and `name`, and becomes
`ConversationDraft`.

The field is a token field: chips for chosen recipients, a cursor after them, results below
as you type. Backspace on an empty cursor removes the last chip — the Messages behaviour
people notice when it is missing.

What the recipients *mean* is not just a count:

| Recipients | Open | Result |
| --- | --- | --- |
| one **person** | off | `roomType=1`, and Talk hands back your existing conversation if you have one |
| one **group or team** | off | `roomType=2` — a group of one invitee is still a group; Talk cannot make a one-to-one with a group |
| two or more | off | `roomType=2` |
| any | on | `roomType=3` — a one-to-one cannot be public, so the toggle overrides the count |

The single-group case is the one easily missed; without it the request fails at the server
with `invite`.

Openness is a toggle in the draft's header. The password stays in Conversation Settings,
which already has both — the draft gets one switch, not two.

The group's name is derived from the chips — "Heine, Lea & Marianne", truncated past three —
because the alternative is `---`. Renaming afterwards already works.

## 3. Sending

Enabled once there is at least one recipient and something to say. Then, in order: create the
room, post the message, hand off to the real conversation.
`AppModel.conversationCreated(_:)` already does the last part, inserting and selecting without
waiting for the sync loop.

For one person this usually creates nothing: Talk returns the existing conversation and the
message lands there. The draft row vanishes and the sidebar selects the row that was already
below it. Worth stating, because from the outside it looks like a bug and is exactly right.

Two failure modes, not symmetrical:

- **Create fails.** Most likely `403 permissions` — `isNotAllowedToCreateConversations` is a
  policy some deployments set. The draft stays as it was, chips and typed text intact, with
  the error under the To: field. Nothing is lost.
- **Create succeeds, the message does not.** An empty conversation now exists, and discarding
  the draft would orphan it. So the draft still clears and the new conversation is still
  selected; the message arrives as a pending one, retryable through the machinery that
  already handles a failed send. The conversation is real, only its first message is late.

### One deliberate cut

No attachments in a draft. `AttachmentQueue` is built with a token and a draft has none, so
the `+` is absent rather than broken. Note for later that the upload half needs no token —
only `share(path:token:)` does — so staging into a tokenless draft and sharing once the room
exists is a small follow-up, not a rewrite. It is simply not this change.

## 4. What goes, and what is tested

`NewConversationSheet` goes entirely: the view, its `.sheet` in `RootView`, and
`isShowingNewConversation`. Three entry points converge on one `AppModel.newMessage()` — ⌘N,
the toolbar's compose button, and the command palette's "New Conversation".

`NEXTCLOUD_API.md` § 11 needs the three findings from § 0 above, none of which it currently
records.

Tested in TalkCore, which is where this repository's tests live:

- **Type inference** — recipients plus the toggle to a `roomType`. A pure function; the table
  in § 2 is its cases, the single-group row included.
- **The derived name** — one person, three, five-and-truncated, and a name that is only emoji
  or only whitespace.
- **`ConversationService.create`** against `StubTransport`: that `participants[users][0]` and
  friends are formed correctly, and that **200 and 201 are told apart**, since that
  distinction is the whole reason messaging someone you already talk to works.
- **The reserved token** — that `#draft` cannot be a real Talk token, so the guard holds.

The To: field, the sidebar row and its ×, and the detail-pane branch are views. This
repository tests `TalkCore` rather than views, so those are checked by hand.
