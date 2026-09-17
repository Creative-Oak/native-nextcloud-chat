# Changelog

## Unreleased

### Intelligence

Everything here works with Apple Intelligence switched off, or missing, except suggested
replies — which is nothing but a model. See
[`docs/plans/2026-09-17-apple-intelligence-design.md`](docs/plans/2026-09-17-apple-intelligence-design.md).

- **Times you type are underlined where you typed them.** “lad os snakke om det i morgen”
  underlines *i morgen* in link blue; clicking it arms a reminder, and sending the message
  sets it. Danish and English, including “på fredag”, “om et par dage”, “i morgen kl. 14”
  and “in two hours” — read on this Mac from a table, not from `NSDataDetector`, which does
  not know any of them. Apple Intelligence, where it is available, adds the phrases the
  table can’t hold.
- **A one-tap row under a message**: **Add to Reminders** when a message names a time,
  **Add to Notes** when it carries a list. Notes go to your Note to self conversation, so
  they are on your phone too. Offered on the newest few messages only, never in a sensitive
  conversation, and a chip that has been used says so.
- **Suggested replies** above the message field, in the conversation’s language and in the
  way you write — primed with your own recent messages. Clicking one puts it *in the field*;
  nothing is ever sent by one click. Needs Apple Intelligence.
- **Writing Tools** in the message field: proofread, rewrite and the tone changes.
- **Reminders can go to Apple Reminders**, Nextcloud’s own, or both — Settings →
  Intelligence. Nextcloud is the default and needs no permission; Reminders.app is asked
  for at the moment it is first needed, and kvidr only ever adds to it.
- Nothing is sent anywhere. The on-device model only, never Private Cloud Compute.

### Eight more, the same day

- **Catch me up.** Forty unread in a busy room: the “New messages” line offers to summarise
  them, and a card appears above the messages it read. Asked for by a click — opening a
  conversation never starts an inference.
- **What needs you.** An orange `?` in the sidebar on conversations whose newest message is
  actually waiting on you, beyond the ones that spell out your name. Questions and plain
  requests are found on this Mac; the ambiguous ones go to the model *in one prompt for the
  whole sidebar*.
- **A rush of notifications becomes one banner.** Three conversations at once, and the
  banners already on screen are replaced by one saying who is waiting and what for. A single
  message still notifies instantly — nothing is buffered or delayed. A mention is never
  swallowed.
- **A poll, read out of the conversation.** “Tirsdag eller onsdag?” across twenty messages
  fills the poll sheet’s question and options — the options people actually raised. You
  still press Create.
- **⇧⌘F understands a question.** “hvad sagde Heine om fakturaen i sidste uge” now finds
  something instead of nothing. A bar under the field always says what was searched, with
  “Use what I typed” one click away.
- **What a long voice message came to.** Under the transcript of anything over about half a
  minute: one line on what it was about, and a ✓ for anything it asked for.
- **Translate a message**, under the original and never in place of it. Apple’s Translation
  framework, so this one works with Apple Intelligence switched off entirely.
- **Send Later knows when they’re back.** Writing to somebody who is out of office, a bar
  over the field offers the morning they return — skipping the weekend. No model at all:
  the server already said they were away.

Three of these need no language model, and three more work at reduced strength without one.
`docs/plans/2026-09-17-apple-intelligence-design.md` § 6 says exactly what each costs.

## 1.0.0

The first release: a native macOS client for Nextcloud Talk's text chat.

### Accounts

- **Login Flow v2 only.** You type a server address, approve in your browser, and the app
  receives a device-specific app password. Your Nextcloud password is never typed into, or
  seen by, this app.
- The app password lives in the **macOS Keychain** — never in preferences, never in the
  cache, never in a log — and is revoked when you remove the account.
- HTTPS is required. Plain HTTP is possible only behind **Settings → Advanced → Allow
  insecure local servers**, and only for `localhost` and private-network addresses.
- Capability discovery on sign-in, refreshed when the server says its Talk configuration
  changed. Every feature below is gated on a capability rather than a version number, so
  anything your server lacks is hidden rather than broken.

### Conversations

- Sidebar with avatars, favourites, unread counts and mention state, grouped into
  Favourites / Conversations / Archived.
- Painted from the local cache before any request is made, which is what makes launch feel
  instant.
- Incremental refresh using the server's own `modifiedSince` cursor.
- Filter (⌘F), quick switcher (⌘K), next unread (⇧⌘]), mark as unread, favourite, mute,
  copy link, open in Nextcloud.
- ⌘N creates a conversation — direct, group or open — using Nextcloud's own people search.
- Moderator settings: rename, description, read-only, message expiration, link access and
  password, leave, delete.

### Reading

- Backwards pagination, message grouping, day separators and a new-messages marker that
  stays put while you read.
- Markdown, mentions, links, code, quotes and rich objects, rendered as native text — never
  as HTML, and never in a web view.
- Inline image previews with an in-app viewer that can save or open in Nextcloud.
- Read markers that move only when you have actually seen a message: the conversation has
  to be selected, the app frontmost, the window key, and the transcript at the bottom.
- Live updates over Talk's long poll, with backoff and a visible reconnecting state.
- Everything readable offline from the cache.

### Writing

- Optimistic sending with retry, replies, editing, deleting, reactions and a who-reacted
  popover.
- Mention autocomplete with Talk's own participant search, including `@all` where the
  server permits it.
- Attachments by drag-and-drop, ⇧⌘A or paste, with real upload progress; a name clash gets
  a numbered name rather than overwriting someone's file.
- Drafts survive quitting, including text typed in the last few hundred milliseconds.

### Finding things

- ⌥⌘F finds in the open conversation, over what you can see, instantly.
- ⇧⌘F searches **the server's whole history** — every conversation, or just this one —
  through Talk's unified search provider, and takes you to the message.

### Around the app

- A third-column inspector: conversation info, participants (invite and remove), and shared
  files by kind.
- Notifications and a Dock badge, with a preview-free mode for shared screens.
- Liquid Glass on macOS 26, applied to the floating layer — message actions, panels,
  reaction pills, upload rows — and deliberately not to the transcript, which is content.
- A keyboard shortcuts window (⌘/), because every command here has a shortcut.

### Not in this release

- **Calls.** Deliberately out of scope; `docs/ARCHITECTURE.md` § Room for calls describes
  what the architecture leaves open for them.
- Typing indicators and user-status editing, which need Talk's signaling API.
- Interactive polls, voice messages, pins and reminders. Polls and voice messages are
  *shown*, not yet answered or played.
