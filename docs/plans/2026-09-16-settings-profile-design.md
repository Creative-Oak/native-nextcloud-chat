# Settings in the window, with your Nextcloud profile — design

*16 September 2026. Replaces the separate Settings window.*

A row at the bottom of the sidebar opens Settings in place of the conversation. At the top,
your picture, name and status; below, your Nextcloud profile, this Mac's sign-in, and the
app's own preferences. Status and picture are edited here. What Nextcloud won't let an app
password change is shown, with a way to change it in the browser.

## 0. What Nextcloud allows an app password

Kvidr signs in through Login Flow v2 and holds an app password, never the account password.
Checked against `nextcloud/server` master, that decides most of the shape:

| | Endpoint | With an app password |
| --- | --- | --- |
| Read profile | `GET /ocs/v2.php/cloud/users/{userId}` | Yes. Every field comes with a `{field}Scope` (`v2-private`, `v2-local`, `v2-federated`, `v2-published`). |
| Edit profile | `PUT /ocs/v2.php/cloud/users/{userId}` | **No.** `#[PasswordConfirmationRequired]`: the session needs `last-password-confirm` from the last 30 minutes, and `Session::logClientIn` only sets that for a real password, never for an app token. |
| Status | `/ocs/v2.php/apps/user_status/api/v1/user_status…` | Yes, no confirmation. Capability `user_status`: `enabled`, `supports_emoji`, `supports_busy`. |
| Picture | `POST` / `DELETE /index.php/avatar/` | Yes. A front-page route, so it needs the `OCS-APIRequest: true` header to pass the CSRF check. A square JPEG or PNG is stored directly; anything else needs a second crop request. |
| Devices | `/index.php/settings/personal/authtokens…` | **No.** There is no endpoint that lists them, and every one that changes them refuses a session that is an app password (`checkAppToken`), on top of strict password confirmation. |

Editing profile details in the app would mean asking for the account password — the thing
the login flow exists to keep out of the app, and something SSO accounts don't have. So it
isn't done.

## 1. Getting there

- **The row.** Pinned to the bottom of the sidebar, below the list: avatar with a status dot,
  display name, a gear. The compact sidebar shows the avatar and dot only. It highlights like
  a selected conversation while Settings is open.
- **What it replaces.** The messages column only. The sidebar stays, no conversation is
  selected, the inspector closes. Selecting a conversation leaves Settings. An unsent New
  Message draft stays where it is.
- **⌘,** opens this page and brings the window forward. The `Settings` scene goes.
- **One value for the column.** `AppModel` says what the messages column shows — a
  conversation, the draft, or Settings — as a single value, so Settings and a selected
  conversation can't both be true. Settings is never restored at launch.
- **Not signed in, or needing sign-in again:** there is no sidebar, so no Settings.

## 2. The page

One grouped, scrolling form.

**Header.**
- *Picture* — click for **Choose Picture…** or **Remove Picture**. The image is centre-cropped
  square and sent as PNG, after a preview sheet confirms it.
- *Display name* and *server* — read-only, with **Edit in Nextcloud…**.
- *Status* — Online, Away, Do not disturb, Invisible, and Busy when the capability says so.
  Under it the message: emoji, text, and clear-after (Don't clear, 30 minutes, 1 hour,
  4 hours, Today, This week), with the server's predefined messages as one-click suggestions.
  Hidden entirely when the status app is off.

**Profile.** The fields that have a value — email, phone, address, website, pronouns,
headline, organisation, role, biography, fediverse, Bluesky, birthdate — each with its
visibility as a small label. **Edit in Nextcloud…** opens Personal info; **View Profile…**
appears when the public profile is enabled.

**This Mac.** Server, Nextcloud and Talk versions, connection state; **Manage Devices in
Nextcloud…**; **Remove Account…**, unchanged (revokes this Mac's app password, deletes the
cache and its key).

**Preferences.** General, Notifications and Advanced, moved from the old window as sections,
content unchanged.

**Saving** happens as you go: a control saves when it's changed, or when a text field is
committed, and shows a spinner, then a checkmark, or the error in place.

## 3. How it's built

**`TalkCore`**
- `ProfileService` — `profile()` decodes into `UserProfile` (fields, scopes, profile
  enabled); `setAvatar(pngData:)` as multipart `files[]` with `OCS-APIRequest`;
  `removeAvatar()`. A refusal carries Nextcloud's own `data.message`.
- `UserStatusService` — `status()`, `predefinedStatuses()`, `setStatus(_:)`,
  `setCustomMessage(icon:message:clearAt:)`, `setPredefinedMessage(id:clearAt:)`,
  `clearMessage()`. `clearAt` is a Unix time.
- `SquareAvatar` — centre-crop and PNG encode, off the main actor.
- `ProfileLinks` — `personalInfo`, `security` and `publicProfile` built from the signed-in
  `ServerAddress` plus a fixed path. Never from a URL in a response.

**App**
- `ProfileModel`, one per session, shared by the sidebar row and the page, so the dot and
  picture agree everywhere. Loads when Settings opens, and again when Kvidr becomes active
  while Settings is showing — which is what picks up an edit made in the browser. Status
  changes are optimistic and roll back with the server's reason.
- After a picture change, the user's own entries leave the avatar cache.
- `SettingsPage` and its sections; `SettingsView.swift`'s scene is removed.
- The picture is chosen in an open panel limited to images and read through
  `FileInspection`, so a file on a dead share can't hang the window. The website field
  becomes a link only through `URL.isOpenableLink`.

## 4. Errors, tests, and what's left out

**Errors.** A refused or offline status change snaps back with the reason; nothing is queued
for later. A profile that won't load shows *Couldn't load your profile* with **Try Again**,
and the rest of the page works. A refused picture keeps the sheet open with the server's
message. A 401 hands over to the existing re-sign-in flow.

**Tests.** Profile decoding with missing fields, empty values and every scope; the exact
request for each status call; the avatar multipart body, header, and both success and
refusal; links built only from the signed-in address; centre-crop of portrait, landscape and
square images.

**By hand.** Change status here and see it in the web UI; change the picture and see it in
the sidebar; edit the headline in the browser and see it on return.

**Left out, on purpose.** Editing profile details in the app (needs the account password). A
device list (no API). Crop and zoom controls. Status that updates live while it changes on
another device.
