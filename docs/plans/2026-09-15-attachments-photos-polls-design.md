# Attachments that wait, a real Photos picker, and polls — design

*15 September 2026. Changes how the composer sends files; adds two items to the + menu.*

Three things, in the order they depend on each other: attachments stop sending themselves
and wait for the send button, the Photos menu item opens the system photo picker rather
than a second file panel, and polls — the only other item in Messages' + menu with a real
Nextcloud Talk counterpart — become a feature.

## 0. What of Messages' + menu is actually possible

Settled before designing, because most of that menu has nothing to send itself as:

| Messages item | Here |
| --- | --- |
| Fotos | Yes — `PhotosPicker` into the existing upload path (§2) |
| Afstemninger | Yes — a real Talk feature, capability `talk-polls` (§3) |
| Image Playground, Genmoji | Possible later: Apple APIs that produce an image, which would feed the same tray. Gated on Apple Intelligence. Not in this design |
| Stickere, Beskedeffekter | No. iMessage-proprietary; there is no wire format to put them in |
| Send senere | No. Nothing server-side; Talk's `remind-me-later` is "remind *me* about this message", not scheduled send. Client-side only would mean "works if the Mac stays awake" |

## 1. Attachments wait for the send button

### The resting state

`FileTransfer.State` already runs `queued → uploading(f) → sharing → completed`, and
`drain()` runs the upload and the share in one pass, which is why a dropped file sends
itself. One new state opens a gap between them:

```
queued → uploading(f) → uploaded ← staged, waiting for you
                            ↓ (send)
                         sharing → completed
```

Attaching still starts the pump immediately — the bytes go up while you type, so send is
near-instant — but the pump now stops at `.uploaded`. Send is what moves every `.uploaded`
transfer on to `.sharing`. Nothing else about the queue changes: one upload at a time, the
same progress reporting, the same retry.

The tray's progress bar means something slightly different as a result: it fills to 90%
while you are typing and finishes when you send. That matches the weighting already in
`FileTransfer.State.fraction`, where "the share is the last tenth".

### The caption

Talk's share step takes a caption in `talkMetaData` (§12 of the API reference), and
`AttachmentService` already passes one through — it has simply never been filled in. A
caption belongs to *one share*, so with several files staged:

- **staged, with text** — the text becomes the caption on the first transfer; the rest
  share bare. One message fewer than sending the text separately.
- **staged, no text** — all share bare.
- **nothing staged** — today's path, untouched.

`send()` currently returns early unless there is text. That guard becomes "text, or
something staged": sending a photo with no words has to work.

### What moves from attach-time to send-time

This is the actual point of the change, and both are bugs today waiting to be noticed:

- **Reply context.** `enqueue(replyTo:)` captures `replyingTo` when the file is picked.
  Pick a file, then decide to reply to something, and the reply is lost. `replyTo` leaves
  the enqueue signature and is read at send, with the caption.
- **The draft and the reply banner.** `ComposerView.choose` calls `cancelReply()` on
  picking. Send does it now.

### Removing a staged file

Removal now has server state behind it, because the bytes are already up. `remove()`
becomes async: cancel the upload if it is in flight, then `DELETE` the file over WebDAV.

If the DELETE fails the file is orphaned in the user's Files. Log it and drop the row
anyway — trapping someone with an attachment they cannot dismiss is worse than a stray
file they can delete in Nextcloud.

### Sending while an upload is still running

Send is a commit, not a wait. The composer clears at once; each transfer shares itself as
its own upload lands; the tray keeps showing progress until the last one is through.

### Drag-and-drop and paste

Both stage, like everything else. The same file behaving differently depending on whether
it arrived from Finder, the clipboard or the picker is not a distinction worth keeping.

## 2. The Photos picker

SwiftUI's `PhotosPicker` (PhotosUI), not `PHPhotoLibrary`.

The reason is permissions. `PhotosPicker` wraps `PHPickerViewController`, which runs **out
of process**: the user picks inside Apple's own UI and only the chosen items cross over.
No authorisation prompt, no `NSPhotoLibraryUsageDescription`, no new entitlement on a
sandboxed app. `PHPhotoLibrary` needs all three, and asks for the whole library in order
to send one photo.

- **Bridging to the queue.** `AttachmentQueue` takes file URLs; a `PhotosPickerItem` is
  not one. `enqueuePastedImage` already solves this shape — write to a temp file, give it
  a real name, hand over the URL — and picked items follow it, keeping the original
  filename where Photos supplies one.
- **Loading.** Through a `Transferable` with a `FileRepresentation`, never
  `loadTransferable(type: Data.self)`: the `Data` route holds a 4GB video in memory before
  a byte is uploaded.
- **Filter.** `.any(of: [.images, .videos])`. Messages' Fotos shows both.
- **HEIC.** Send the original, unconverted. Nextcloud generates previews server-side, so
  it renders in Talk everywhere; only downloading the original on an older OS could
  disappoint, and that is better than re-encoding everyone's photos a generation down.
- **Files…** keeps `NSOpenPanel`, unchanged.

## 3. Polls

### The service

`PollService`, shaped like `ConversationService`, on
`/ocs/v2.php/apps/spreed/api/v1/poll/{token}`:

| Method | Path | Parameters |
| --- | --- | --- |
| POST | `/poll/{token}` | `question`, `options[]`, `resultMode`, `maxVotes` |
| GET | `/poll/{token}/{pollId}` | — |
| POST | `/poll/{token}/{pollId}` | `optionIds[]` |
| DELETE | `/poll/{token}/{pollId}` | — |

`resultMode` 0 shows results immediately, 1 hides them until the poll closes. `maxVotes`
is how many options one participant may pick.

Gated on `talk-polls` (Talk 15), which `CapabilitySnapshot` does not read yet.

**Before implementing:** these endpoints are not yet in `NEXTCLOUD_API.md`, so by the rule
at the top of that file they are not verified. Check the response shape — `status`,
`details`, how `votes` is keyed — against `spreed/openapi-full.json`, then add the section.
Nothing here should be built on the readthedocs summary alone.

### Rendering

A poll arrives as an ordinary message whose `messageParameters` carry an object of type
`talk-poll` with only **id** and **name** — the question, and nothing else. §6's rule is
that unknown rich types render as their `name`, so a poll today is a line of text that
happens to be a question. The card fetches the rest by id when it first appears.

**Vote counts are not live, on purpose.** Nobody else's vote produces a chat message, and
this project does not use the signaling API (§9). So the card loads on appear, refetches
after your own vote, and refetches on close — which *does* arrive as a message. Between
those a count can be stale. The alternative is a timer per visible poll quietly polling
the server for the life of the window, which is worse.

### Composing and closing

A **Poll…** item in the + menu opens a sheet: the question, a list of options that can be
added to and reordered, single-vs-multiple choice (`maxVotes`), and results-visible-now vs
hidden-until-closed (`resultMode`). Closing is offered to the poll's author and to
moderators.

## 4. Testing

- `PollService` against `StubTransport`, as the other services are: each of the four calls,
  the `talk-polls` gate, and the two response shapes (`resultMode` 0 and 1).
- The staging change is where the regressions will be. Worth a test each for: a caption
  landing on the first transfer and not the rest; send with attachments and no text; a
  reply chosen *after* the file was attached; and remove-while-uploading cancelling before
  it deletes.
- The picker and the sheet are UI, and this repository tests `TalkCore` rather than views —
  so those are checked by hand.
