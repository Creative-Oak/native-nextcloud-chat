# Changelog

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
