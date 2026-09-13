# Nextcloud / Nextcloud Talk API reference (verified)

Everything in this file was checked against primary sources on 2026-09-13. Where the prose
documentation was vague, the **OpenAPI descriptions the server itself ships** were used
instead — they are generated from the implementation and settled three shapes the prose got
wrong or left out (see § 11). Sources:

- Talk API docs — <https://nextcloud-talk.readthedocs.io/en/latest/>
  (`global`, `conversation`, `chat`, `reaction`, `participant`, `avatar`,
  `capabilities`, `constants`)
- Server developer manual — Login Flow v2, OCS API overview
- `nextcloud/server` → `lib/public/RichObjectStrings/Definitions.php` for the
  rich-object parameter schema
- `nextcloud/server` → `core/openapi.json` and `apps/files_sharing/openapi.json`
- `nextcloud/spreed` → `openapi-full.json` (Talk's own generated API description)

**Rule for this project:** if an endpoint, parameter or field is not in this file,
it has not been verified — go and verify it, then add it here. Do not invent fields.

---

## 1. OCS basics

All OCS calls live under `/ocs/v2.php/…`. We use **v2 only**.

**Required on every OCS request**

| Header | Value |
| --- | --- |
| `OCS-APIRequest` | `true` |
| `Accept` | `application/json` |
| `Authorization` | `Basic base64(loginName:appPassword)` |
| `User-Agent` | `Talk for Mac/<version> (macOS)` |

**Envelope**

```json
{ "ocs": { "meta": { "status": "ok", "statuscode": 200, "message": "OK",
                     "totalitems": "", "itemsperpage": "" },
           "data": … } }
```

- With `/ocs/v2.php`, `meta.statuscode` mirrors HTTP semantics (`200`, `201`, `404`…)
  **and** the HTTP status line carries the real code. (With `/ocs/v1.php` the HTTP
  status is always 200 and success is `meta.statuscode == 100`. We do not use v1,
  but the decoder accepts `100` as success so a v1 URL can never silently "fail".)
- `meta.totalitems` / `meta.itemsperpage` are strings, and are frequently `""`.
- `data` is `[]` (empty **array**) in several "nothing here" responses even where the
  success shape is an object. The decoder must tolerate this.

**Status codes we handle centrally** — see `OCSError` in `Sources/TalkCore/Networking`.

| Code | Meaning for us |
| --- | --- |
| 304 | Not modified (conditional conversation fetch) — keep cache |
| 401 | App password revoked/expired → mark account `needsReauthentication` |
| 403 | Permission denied (e.g. no `256` reaction permission, read-only room) |
| 404 | Gone / not a participant / poll pending (Login Flow v2 uses 404 as "keep polling") |
| 409 | Conflict (e.g. session conflict on join) |
| 412 | Precondition failed — **Talk-specific: the conversation session is gone; re-join** |
| 413 | Message too long (`config.chat.max-length`) |
| 426 | Client too old; `ocs.meta.message` holds the minimum required version |
| 429 | Rate limited / brute-force protection → exponential backoff |
| 503 | Maintenance mode (`X-Nextcloud-Maintenance-Mode: 1`) → backoff, stay offline-ish |

Talk-specific extras from the `global` docs: **406** = endpoint has no federation support
when called on a proxy (federated) conversation; **422** = the remote federation host is
unreachable (except for leave-room, which is processed locally).

---

## 2. Authentication — Login Flow v2

Verified against the server developer manual.

### 2.1 Start

```
POST {server}/index.php/login/v2
```

No auth. Send a descriptive `User-Agent` — **it becomes the name of the app password
in the user's Security settings**, so we send `Talk for Mac (<host name>)`.

Response (plain JSON, *not* an OCS envelope):

```json
{ "poll": { "token": "<64 chars>", "endpoint": "https://…/login/v2/poll" },
  "login": "https://…/login/v2/flow/<token>" }
```

The flow is valid for **20 minutes**.

### 2.2 User step

Open `login` in the **default browser** (`NSWorkspace.open`). The user signs in,
completes 2FA, and presses *Grant access*.

### 2.3 Poll

```
POST {poll.endpoint}
Content-Type: application/x-www-form-urlencoded
token=<poll.token>
```

- `404` → not granted yet. Keep polling.
- `200` → success, **returned exactly once**:

```json
{ "server": "https://cloud.example.com",
  "loginName": "alice",
  "appPassword": "xxxxx-xxxxx-xxxxx-xxxxx-xxxxx" }
```

Poll about once per second; we back off gently and give up after 20 minutes.
`appPassword` goes straight into the Keychain and never into a log, a `UserDefaults`
key, or the database.

### 2.4 Afterwards

- Authenticate everything with **HTTP Basic** `loginName:appPassword`.
- `GET /ocs/v2.php/cloud/user` → confirms credentials and gives the canonical `id`
  (which can differ from `loginName`), `display-name`, `email`.
- `DELETE /ocs/v2.php/core/apppassword` → invalidate this device's app password.
  We call this on "Remove account" (best effort) before deleting the Keychain item.

---

## 3. Capabilities

```
GET /ocs/v2.php/cloud/capabilities
```

Anonymous call also works and is how we detect "is this even a Nextcloud server"
before login. Shape:

```json
{ "ocs": { "data": {
  "version": { "major": 32, "minor": 0, "micro": 0, "string": "32.0.0", "edition": "" },
  "capabilities": {
    "core": { "pollinterval": 60, "webdav-root": "remote.php/webdav" },
    "spreed": {
      "features": ["chat-v2", "reactions", "edit-messages", …],
      "features-local": [ … ],
      "config": { "attachments": {…}, "call": {…}, "chat": {…},
                  "conversations": {…}, "federation": {…}, "previews": {…},
                  "signaling": {…}, "permissions": {…}, "feature-hints": {…} },
      "config-local": { … },
      "version": "21.0.4"
    } } } } }
```

`features` is a flat array of strings. **Every optional behaviour in this app is gated
on a string in that array** — never on a version comparison.

### Capability strings we actually rely on

| Capability | Talk version | Gates |
| --- | --- | --- |
| `chat-v2` | 3.2 | Baseline. Absent → refuse to run against this server. |
| `chat-read-marker` | 7.0 | `POST /chat/{token}/read` |
| `chat-unread` | 14 | `DELETE /chat/{token}/read` (mark as unread) |
| `chat-read-status` | 11 | Show "read by everyone" via `lastCommonReadMessage` |
| `chat-reference-id` | 9.0 | Optimistic-send reconciliation via `referenceId` |
| `chat-replies` | 8.0 | `isReplyable` / `replyTo` |
| `chat-get-context` | 16 | `GET /chat/{token}/{messageId}/context` (jump to a message) |
| `reactions` | 14 | Reaction API + reaction UI |
| `edit-messages` | 19 | `PUT /chat/{token}/{messageId}` |
| `edit-messages-note-to-self` | 20 | Editing in Note to Self without the general cap |
| `delete-messages` | 11.1 | `DELETE /chat/{token}/{messageId}` (6-hour window) |
| `delete-messages-unlimited` | 19 | Same, without the 6-hour window |
| `rich-object-delete` | 14 | Deleting file/rich-object messages |
| `markdown-messages` | 17.1 | Trust the per-message `markdown` flag |
| `silent-send` / `silent-send-state` | 15 / 19 | Send without notifying / render the silent flag |
| `message-expiration` | 15 | Honour `expirationTimestamp` |
| `mention-flag` | 4.0 | `unreadMention` |
| `direct-mention-flag` | 13 | `unreadMentionDirect` |
| `mention-permissions` | 20 | Whether `@all` is allowed for this user |
| `favorites` | 4.0 | Favourite/pin section in the sidebar |
| `notification-levels` | 5.0 | Per-conversation notification level |
| `avatar` | 17 | Conversation avatar endpoints + `avatarVersion` |
| `note-to-self` | 18 | `GET /room/note-to-self` |
| `archived-conversations-v2` | 20.1 | `isArchived` handling |
| `conversation-permissions` | 13 | `permissions` bitmask is meaningful |
| `session-state` | 18 | `PUT /room/{token}/participants/state` |
| `remind-me-later` | 17.1 | Message reminders (phase 7) |
| `clear-history` | 12.1 | Clear conversation history (phase 7) |
| `rich-object-list-media` | 14 | Shared-items browser (phase 7) |
| `federation-v1` / `federation-v2` | 19 / 20 | Federated conversations |
| `talk-polls` | 15 | Polls (phase 7) |
| `typing-privacy` | 17 | Typing indicators (phase 7, needs signaling) |
| `pinned-messages` | 23 | Pins (phase 7) |
| `threads` | 22 | Threads (not planned for v1) |

### Config values we read

| Path | Use |
| --- | --- |
| `config.chat.max-length` | Composer character limit (default 32000) |
| `config.chat.read-privacy` | `0` public / `1` private — whether read receipts mean anything |
| `config.chat.typing-privacy` | Typing indicator opt-out |
| `config.attachments.allowed` | Show/hide the attachment affordance |
| `config.attachments.folder` | Default upload target (phase 7) |
| `config.conversations.can-create` | Enable/disable ⌘N |
| `config.previews.max-gif-size` | Inline GIF policy (phase 7) |
| `config.call.enabled` | Only used to explain that calls live elsewhere |

### Cache invalidation

Talk responses carry **`X-Nextcloud-Talk-Hash`** (SHA1 of the server's Talk config).
When the value changes, the client must re-fetch capabilities. We watch this header on
every Talk response and refresh capabilities when it moves.

---

## 4. Conversations — `/ocs/v2.php/apps/spreed/api/v4`

v4 is current (v1–v3 removed). Endpoints we use:

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/room` | List conversations. Params: `noStatusUpdate=1`, `includeStatus=true`, `modifiedSince=<ts>` |
| GET | `/room/{token}` | Single conversation |
| GET | `/room/note-to-self` | Cap `note-to-self`; auto-creates |
| POST | `/room` | Create. `roomType`, `invite`, `source`, `roomName` |
| POST/DELETE | `/room/{token}/favorite` | Cap `favorites` |
| POST | `/room/{token}/notify` | `level` (cap `notification-levels`) |
| GET | `/room/{token}/participants` | `includeStatus` |
| POST | `/room/{token}/participants/active` | Join (creates a session). Optional `password`, `force` |
| DELETE | `/room/{token}/participants/active` | Leave session |
| PUT | `/room/{token}/participants/state` | Cap `session-state` — background/active |
| GET | `/room/{token}/avatar`, `/avatar/dark` | Cap `avatar` |

### Response headers on `GET /room`

| Header | Use |
| --- | --- |
| `X-Nextcloud-Talk-Hash` | Capability invalidation (see above) |
| `X-Nextcloud-Talk-Modified-Before` | **Feed this back as the next `modifiedSince`** |
| `X-Nextcloud-Talk-Federation-Invites` | Pending federation invites (badge, phase 7) |

### `modifiedSince` semantics — important

`modifiedSince` returns only conversations whose `lastActivity` is newer. It **cannot
express deletions, removals, or "you were disinvited"**. Therefore:

- incremental refresh (cheap) → `modifiedSince`, merge results, never delete
- full refresh (periodic + on wake/foreground) → no `modifiedSince`, and conversations
  absent from the response are removed locally

Our policy: incremental every 30 s while active; full refresh on launch, on window
activation after >5 min idle, on network recovery, and at most every 5 minutes.

### Conversation fields we model

`id`, `token`, `type`, `name`, `displayName`, `description`, `participantType`,
`attendeeId`, `actorType`, `actorId`, `permissions`, `attendeePermissions`,
`defaultPermissions`, `readOnly`, `listable`, `messageExpiration`, `hasPassword`,
`hasCall`, `callFlag`, `canStartCall`, `canDeleteConversation`, `canLeaveConversation`,
`lastActivity`, `isFavorite`, `isArchived`, `notificationLevel`, `notificationCalls`,
`lobbyState`, `lobbyTimer`, `unreadMessages`, `unreadMention`, `unreadMentionDirect`,
`lastReadMessage`, `lastCommonReadMessage`, `lastMessage`, `objectType`, `objectId`,
`avatarVersion`, `isCustomAvatar`, `mentionPermissions`, `status`, `statusIcon`,
`statusMessage`, `statusClearAt`.

Two traps, both handled in `ConversationDTO`:

1. `lastMessage` is normally a message object, but Talk sends **`[]`** for a
   conversation with no messages. Decode as "object or empty array".
2. Fields marked "requires capability" are simply **absent** on older servers —
   every one of them decodes as optional with a sane default.

### Constants (verified)

```
Room type          1 one-to-one · 2 group · 3 public · 4 changelog
                   5 former one-to-one · 6 note to self
Read-only          0 read-write · 1 read-only
Listable           0 participants · 1 users · 2 everyone
Lobby              0 none · 1 non-moderators
Participant type   1 owner · 2 moderator · 3 user · 4 guest
                   5 user-following-link · 6 guest moderator
Notification level 0 default · 1 always · 2 mention · 3 never
Call notification  0 off · 1 on
SIP                0 disabled · 1 enabled (PIN) · 2 enabled (no PIN)
Mention perms      0 everyone · 1 moderators
Permissions bits   0 default · 1 custom · 2 start call · 4 join call · 8 ignore lobby
                   16 publish audio · 32 publish video · 64 publish screen
                   128 post messages/share · 256 add reactions
In-call flags      0 disconnected · 1 in call · 2 audio · 4 video · 8 SIP
Breakout mode      0 unset · 1 automatic · 2 manual · 3 free
Recording          0 none · 1 video · 2 audio · 3 starting video
                   4 starting audio · 5 failed
```

`128` (post messages) gates the composer; `256` (react) gates reactions. Absence of a
bit means the **server** will refuse — the UI disabling it is a courtesy, never the
authorization.

---

## 5. Chat — `/ocs/v2.php/apps/spreed/api/v1`

### 5.1 Receive messages — `GET /chat/{token}`

| Param | Default | Meaning |
| --- | --- | --- |
| `lookIntoFuture` | — | `1` = long poll for new messages, `0` = read history backwards |
| `limit` | 100 | max **200** |
| `lastKnownMessageId` | — | cursor |
| `lastCommonReadId` | — | send our known value so the server can tell us when it moves |
| `timeout` | 30 | seconds, max **60**; only meaningful with `lookIntoFuture=1` |
| `setReadMarker` | 1 | **we send `0` unless the conversation is genuinely visible** |
| `includeLastKnown` | 0 | include the cursor message itself |
| `noStatusUpdate` | 0 | `1` = don't touch the user's online status |
| `markNotificationsAsRead` | 1 | `0` when reading in the background |

Response headers: **`X-Chat-Last-Given`** (cursor for the next call) and
**`X-Chat-Last-Common-Read`**.

Status: `200` messages, `304` nothing happened within `timeout` (normal!),
`404` gone, `412` session lost → re-join the room.

History reads return messages **newest → oldest**; future reads return
**oldest → newest**. The sync engine normalizes this.

### 5.2 Send — `POST /chat/{token}`

`message`, `actorDisplayName` (guests only), `replyTo`, `referenceId`, `silent`.
→ `201` with the created message. Errors: `400`, `403` (no post permission), `404`,
`412`, `413` (too long), `429`.

`referenceId` is documented as a SHA-256-shaped string; we send
`sha256(UUID)` hex so it is opaque and collision-free. Reconciliation of an optimistic
message is: match on `referenceId` first, fall back to (actorId, message text,
timestamp ±90 s) when the server lacks `chat-reference-id`.

### 5.3 Edit / delete

- `PUT /chat/{token}/{messageId}` with `message` — cap `edit-messages`.
  `200` edited, `202` edited but federation/bridge lag, `403` not yours / too old,
  `405` not editable (system message, file share…).
- `DELETE /chat/{token}/{messageId}` — cap `delete-messages`.
  `200`/`202`, `403`, `405`. The response body is the **replacement** message
  (`messageType: "comment_deleted"`), so we overwrite rather than remove the row.

Both return a system message `message_deleted` / `message_edited` in the stream, which
we consume to update the cache but never render.

### 5.4 Read markers

- `POST /chat/{token}/read` with `lastReadMessage` — cap `chat-read-marker`.
- `DELETE /chat/{token}/read` — mark unread, cap `chat-unread`.

### 5.5 Other chat endpoints (phase 7)

`GET /chat/{token}/{messageId}/context` (cap `chat-get-context`),
`POST|GET|DELETE /chat/{token}/{messageId}/reminder` (cap `remind-me-later`),
`DELETE /chat/{token}` clear history (cap `clear-history`),
`POST /chat/{token}/share` rich object (cap `rich-object-sharing`),
`GET /chat/{token}/share[/overview]` (cap `rich-object-list-media`),
`GET /chat/{token}/mentions?search=…&limit=…&includeStatus=…` for mention autocomplete.

File sharing is *not* a Talk endpoint — it is the Files sharing API:

```
POST /ocs/v2.php/apps/files_sharing/api/v1/shares
shareType=10 shareWith=<conversation token> path=<path in user root>
referenceId=<…> talkMetaData={"messageType":"comment","caption":"…","replyTo":123}
```

### 5.6 Message object

| Field | Notes |
| --- | --- |
| `id` | int, monotonically increasing per server |
| `token` | conversation token |
| `actorType` | `users`, `guests`, `bots`, `bridged`, `emails`, `federated_users`, `deleted_users` |
| `actorId`, `actorDisplayName` | display name may be empty |
| `timestamp` | Unix seconds, UTC |
| `systemMessage` | `""` for normal messages, otherwise the system event name |
| `messageType` | `comment`, `comment_deleted`, `system`, `command`, `voice-message`, `record-audio`, `record-video` |
| `message` | text **with `{placeholder}` tokens** |
| `messageParameters` | dict placeholder → rich object (see §6). `[]` when empty. |
| `isReplyable` | cap `chat-replies` |
| `referenceId` | cap `chat-reference-id` |
| `parent` | full parent message object (optional) |
| `reactions` | `{"👍": 3}` — emoji → count. `[]` when empty. |
| `reactionsSelf` | `["👍"]` — emoji I used. Absent/`[]` when none. |
| `markdown` | bool, cap `markdown-messages` |
| `expirationTimestamp` | 0 = never |
| `lastEditActorType` / `lastEditActorId` / `lastEditActorDisplayName` / `lastEditTimestamp` | cap `edit-messages` |
| `silent` | cap `silent-send-state` |
| `deleted` | present (true) on tombstones |

---

## 6. Rich objects (`messageParameters`)

Verified against `lib/public/RichObjectStrings/Definitions.php`.

The message text contains `{key}` placeholders; `messageParameters[key]` is an object
with a `type` plus type-specific keys. Required keys marked **bold**.

| type | keys |
| --- | --- |
| `user` | **id**, **name**, `server` |
| `guest` | **id**, **name** |
| `user-group` | **id**, **name** |
| `call` | **id**, **name**, **call-type**, `link`, `icon-url`, `message-id` |
| `file` | **id**, **name**, **path**, `size`, `link`, `mimetype`, `preview-available`, `mtime`, `etag`, `permissions`, `width`, `height`, `blurhash`, `hide-download` |
| `geo-location` | **id**, **name**, **latitude**, **longitude** |
| `talk-poll` | **id**, **name** |
| `talk-attachment` | **id**, **name**, **conversation**, `mimetype`, `preview-available` |
| `deck-card` | **id**, **name**, **boardname**, **stackname**, **link** |
| `highlight` | **id**, **name**, `link` |
| `email` | **id**, **name** |
| `circle` | **id**, **name**, **link** |
| `open-graph` | **id**, **name**, `description`, `thumb`, `website`, `link` |

Talk also uses `mention-user…`, `mention-call`, `mention-group`,
`mention-federated-user` placeholder *keys*, whose `type` is `user` / `call` /
`user-group` / `user` with `server`. The `{actor}` key on system messages is a `user`.

**Any unknown type renders as its `name`** — never as raw protocol text, never as HTML.

---

## 7. Reactions — `/ocs/v2.php/apps/spreed/api/v1`

Cap `reactions` (Talk 14+). Attendee permission bit `256` required.

| Method | Path | Params |
| --- | --- | --- |
| POST | `/reaction/{token}/{messageId}` | `reaction` (emoji) → `201` new / `200` already existed |
| DELETE | `/reaction/{token}/{messageId}` | `reaction` → `200` |
| GET | `/reaction/{token}/{messageId}` | optional `reaction` filter |

All three return the **full reaction map for the message**
(`{"👍":[{actorType,actorId,actorDisplayName,timestamp}, …]}`), which we fold straight
back into the cached message.

---

## 8. Avatars

| What | URL |
| --- | --- |
| User | `{server}/index.php/avatar/{userId}/{size}` and `…/{size}/dark` |
| Conversation | `{server}/ocs/v2.php/apps/spreed/api/v1/room/{token}/avatar` (+ `/dark`), cap `avatar` |
| Federated user | `…/api/v1/proxy/{token}/user-avatar/{size}` (+ `/dark`), `size` ∈ {64, 512}, cap `federation-v1` |

Cache key includes the conversation's `avatarVersion` so a changed avatar busts the
cache, and nothing else does. Sizes we request: 64 (sidebar/@2x 32pt) and 128.

---

## 11. Participants, people search, and conversation management

### Participants — `/ocs/v2.php/apps/spreed/api/v4`

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/room/{token}/participants` | `includeStatus` |
| POST | `/room/{token}/participants` | `newParticipant` (required), `source` |
| DELETE | `/room/{token}/attendees` | `attendeeId` — **note the different path** |
| DELETE | `/room/{token}/participants/self` | Leave |

`source` is an enum, verified from Talk's OpenAPI:
`users`, `groups`, `circles`, `emails`, `federated_users`, `phones`, `teams`.

Participant fields: `attendeeId`, `actorType`, `actorId`, `invitedActorId`, `displayName`,
`participantType`, `permissions`, `attendeePermissions`, `lastPing`, `inCall`, `sessionIds`,
`status`/`statusIcon`/`statusMessage`/`statusClearAt`, `attendeePin`, `roomToken`,
`phoneNumber`, `callId`.

**Trap:** `sessionIds` contains the string `"0"` for a participant with no session. Treating
a non-empty array as "online" marks everybody online.

### Creating a conversation — `POST /room`

`roomType` (required), plus `roomName`, `invite`, `source`, `description`, `password`,
`readOnly`, `listable`, `messageExpiration`, `lobbyState`, `permissions`, `mentionPermissions`,
`recordingConsent`, `emoji`, `avatarColor`, `participants`, `owner`, `preset`.

We send only `roomType`, `roomName`, `invite`, `source`, `description` and `password`.
`invite` carries one invitee; the rest are added afterwards via the participants endpoint.

### Managing one

| Method | Path | Parameter |
| --- | --- | --- |
| PUT | `/room/{token}` | `roomName` |
| PUT | `/room/{token}/description` | `description` (cap `room-description`) |
| PUT | `/room/{token}/read-only` | `state` 0/1 (cap `read-only-rooms`) |
| POST | `/room/{token}/message-expiration` | `seconds`, 0 disables (cap `message-expiration`) |
| PUT | `/room/{token}/password` | `password` |
| POST/DELETE | `/room/{token}/public` | optional `password` |
| DELETE | `/room/{token}` | — |

### People search — Nextcloud core, not Talk

```
GET /ocs/v2.php/core/autocomplete/get
    search (required) · itemType · itemId · shareTypes[] · limit · sorter
```

Talk passes `itemType=call` and `itemId=<token>` (or `new`). `shareTypes[]`: `0` users,
`1` groups, `7` teams/circles.

Result fields (from core's `AutocompleteResult` schema): `id`, `label`, `icon`, `source`,
`status`, `subline`, `shareWithDisplayNameUnique`.

**Trap:** `status` is an object when the user has one and an **empty string** when they
don't. A decoder that expects an object every time fails the whole search.

## 12. Attachments

Three steps, none of them a Talk endpoint except the last:

1. **Upload** — `PUT /remote.php/dav/files/{userId}/{path}`, Basic auth.
   Useful headers: `X-NC-WebDAV-Auto-Mkcol: 1` (create missing parents instead of a separate
   `MKCOL`), `OC-Total-Length`, and `If-None-Match: *` so the PUT only creates and can never
   silently replace someone's file. A clash answers 412, and we retry with a numbered name.
2. **Share into the conversation** —
   `POST /ocs/v2.php/apps/files_sharing/api/v1/shares` with `shareType=10` (Talk
   conversation), `shareWith=<token>`, `path=<path in the user's root>`, `referenceId`, and
   `talkMetaData` as a JSON string (`messageType`, `caption`, `replyTo`, `threadId`,
   `threadTitle`, `silent`).
3. **Thumbnails** — `GET /index.php/core/preview?fileId=&x=&y=&a=1&forceIcon=0&mode=cover`.
   `forceIcon=0` makes the server answer 404 rather than a generic document icon, so the UI
   can draw its own symbol instead of a picture of one.

### Shared items — `/ocs/v2.php/apps/spreed/api/v1` (cap `rich-object-list-media`)

| Method | Path | Parameters |
| --- | --- | --- |
| GET | `/chat/{token}/share/overview` | `limit` (default 7) |
| GET | `/chat/{token}/share` | `objectType` (required), `lastKnownMessageId`, `limit` |

**Trap, and the reason to read the OpenAPI:** the overview's `data` is a map of
*objectType → array of messages*, but a single type's listing is a map of
*message id → message* — an object, not an array.

## 9. Things this project deliberately does not use

- The **signaling** API (internal + external). Not documented as a stable client API,
  and the MVP must not depend on it. Typing indicators and instant push are the things
  we give up; long polling covers the rest. Isolated behind `LiveUpdateTransport` so an
  implementation can be dropped in later.
- **Notifications OCS API** (`/ocs/v2.php/apps/notifications/api/v2/notifications`).
  Considered; for the MVP the chat long poll already tells us everything for the active
  conversation and the conversation poll covers the rest. Listed as a phase-7 option
  for a single cheap poll that covers *all* conversations at once.
- **WebDAV** — needed for attachments in phase 7 (`/remote.php/dav/files/{userId}/…`),
  unused in the MVP.

## 10. True push notifications — what it would take

A macOS app that is not running cannot poll. Nextcloud's push
(`/ocs/v2.php/apps/notifications/api/v2/push`) is built for the proprietary
Nextcloud push proxy, which forwards to APNs/FCM using the *Nextcloud* app's
certificates. For Talk for Mac to receive push while terminated we would need:

1. An Apple Developer account and an APNs key for `dk.creativeoak.TalkForMac`.
2. Registration of a device token + an RSA public key with the Nextcloud server
   (`POST …/api/v2/push`, fields `pushTokenHash`, `devicePublicKey`, `proxyServer`).
3. A push proxy we host that speaks Nextcloud's proxy protocol and relays to APNs.
4. Decryption of the RSA-encrypted notification payload on device.

Until then: the app follows the normal macOS messaging-app model — it keeps running
after its last window closes, and syncs while running. This is documented behaviour,
not a bug, and there is no fake push architecture anywhere in the codebase.
