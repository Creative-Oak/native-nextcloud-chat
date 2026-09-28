# Manual tests

What still needs a person, a real server and a second device: the things `Tools/preflight.sh`
can't check. Each section is a feature waiting for its test run. Tick the boxes as you go; a
section that passes is committed and moves to **Passed**, with the date.

Log lines quoted below can be read with:

```bash
log show --predicate 'subsystem == "app.kvidr.mac"' --last 10m --info
```

---

## Waiting

### Calls on LiveKit's WebRTC (regression)

WebRTC now comes from LiveKit's build (`livekit/webrtc-xcframework`, M150) instead of
stasel's (M153): the same library with the pieces Live Captions needs added. Nothing about
calls should look or sound different — this is a check that nothing broke.

- [x] kvidr launches (no `dyld` "Library not loaded" crash at start).
- [x] Call your phone: audio both ways.
- [x] Camera: yours reaches the phone, theirs shows in kvidr. Video fills its tile with no
      stretching, and your own is mirrored.
- [x] Switch microphone and speaker from More, e.g. to AirPods: audio keeps working after the
      short gap. FAILED 2026-09-23: after a switch the phone went silent — kvidr asked for the
      phone's media while it was still rejoining, the server said "not allowed", and it never
      asked again. Fixed: the ask waits until kvidr is back in. The log after a switch shows
      `Call: requesting offer from …` after `publisher connected=true`, with no `not_allowed`.
- [x] Switching the speaker away from AirPods Pro while their microphone is still in use: if
      the sound stays in the AirPods, try switching the microphone to the Mac's too (macOS
      tends to keep a headset's output while its microphone is open).
- [x] Turn the camera on while the phone is still ringing, then answer: the phone shows your
      video without turning it off and on again. (Was: the repeats of "camera on" for someone
      who joins went only through signaling, which Talk for iOS ignores.) Passed 2026-09-23 —
      a few seconds' wait on the phone when the camera was on before it answered.
- [x] Drag your own corner tile on the stage with the camera on: it moves and snaps as before.
- [x] While sharing your screen, drag the mini call by its pictures or its glass edge: it
      moves. Its buttons still work.
- [x] Share your screen, and have the phone share its screen: both still show.
- [x] Hang up from kvidr and from the phone: both end the call as before.
- [ ] Echo: with the Mac's speakers (not headphones), the phone doesn't hear itself back.
      Test it with the phone in another room (or someone else calling): two devices in one
      room always loop through each other's speakers and sound distorted, whatever the app.
      2026-09-23: echo cancelling, noise suppression and automatic gain are now switched on
      explicitly in kvidr's own audio processing (it was left to defaults after the swap).

### Live Captions

What everyone in a call says, written out as they say it, above the controls, each line under
the speaker's name. Apple's speech models, on this Mac. Danish uses the dictation model (the
general one has no Danish); English uses the general one, which punctuates better.

- [x] In a call, open More: a **Captions** section with **Live Captions**. Turn it on.
      "Getting captions ready…" shows briefly, then goes.
- [x] Talk on the phone in Danish: their words appear under their name as they speak, the
      newest words a little lighter until they settle. The log says
      `Captions: on, da_DK with the dictation model`.
- [ ] Talk into the Mac: your words appear under **You**. FAILED 2026-09-23 — nothing of
      yours was written out. Two log lines now say why: `Captions: WebRTC's microphone
      processing started, …` (missing: WebRTC never hands the microphone over) and, five
      seconds into talking, `Captions: hearing this Mac's microphone, … loudest 0.xxxx`
      (near 0 while you talk: the audio is scaled wrong). Send those lines.
- [ ] Mute, and keep talking: nothing of yours is written out. Unmute: it picks up again.
- [ ] Stop talking for a few seconds: the next words start a new line. About seven seconds
      after everyone stops, the captions box goes away.
- [ ] Talk over each other: each of you keeps your own line.
- [ ] More → Captions → Language: pick English and speak English — it switches, and punctuates.
      Pick Automatic again.
- [ ] Hang up and call again: captions come back on by themselves (remembered).
- [ ] Settings → Calls: the same switch and the full language list; changing either during a
      call changes the call's captions straight away.
- [ ] Group call (three or more): everyone's lines carry their own name.
- [ ] A language macOS hasn't downloaded yet: "Downloading … for captions… n %", then captions.
- [ ] Share your screen with captions on: the floating mini call has a small captions box
      under the two tiles — the latest two lines, each after the speaker's name, "Live Captions"
      while nobody talks. The box keeps its size as lines come and go.
- [ ] While sharing, turn captions off and on in Settings → Calls: the mini call shrinks and
      grows downwards, its top edge staying put.

### Group calls

Needs three or more people in a call — the phone plus the web app in a browser works.

- [ ] Tiles fill the stage with no scrolling, all the same size and as large as fits: two side
      by side on a wide window, stacked on a narrow one; three as two over one, the one centred.
- [ ] Resize the window: the tiles rearrange to fit.
- [ ] Camera-off tiles: the picture is in proportion to the tile — large with few people, small
      with many.
- [ ] Someone joins: the others slide aside for the new tile, and "Anna joined" shows under the
      header for about three seconds. Someone leaves: "Anna left", and the rest close up.
- [ ] Joining a call that's already going doesn't list everyone who was there as "joined".
- [ ] Switching microphone mid-call (which rejoins) doesn't announce everyone again either.
- [ ] The header shows the group's name, and under it the timer with "· 3 people" (you included).
- [ ] In a one-to-one: no notices, no count, the other person's name as before.
- [ ] Share your screen in a group: the mini call shows whoever spoke last, "Anna +2", and rings
      while they talk.

### Lobby

Needs a group conversation where you're a moderator, and a second account that isn't one (the
web app in a private window works).

- [ ] As moderator: conversation settings → **Lobby** section. Turn the lobby on, Save. A bar at
      the top says "Lobby is on — only moderators can see this conversation", with **Open Now**.
- [ ] As the other account in kvidr: the conversation shows "You’re in the lobby" with its
      picture and description, and no messages, no composer, no call button. The log says
      `Waiting in the lobby` — and no repeated "Chat session expired; re-joining".
- [ ] Moderator clicks **Open Now**: the waiting account's conversation comes in by itself
      within a few seconds (the log says `The lobby opened`), with messages and composer.
- [ ] Lobby on with **Open automatically** a couple of minutes ahead: the waiting screen says
      "Opens in 2 minutes · <time>"; at that time the conversation comes in by itself.
- [ ] The moderator's bar says "Lobby is on — opens <time>" while a time is set.
- [ ] Lobby turned on while the other account has the conversation open: it switches to the
      waiting screen.
- [ ] One-to-ones have no Lobby section.

### Breakout rooms

Needs a group conversation where you're a moderator, with two or three others in it (the web
app in private windows works for them).

- [ ] Inspector → Details: a **Breakout Rooms** card with **Set Up Breakout Rooms…**. Only for
      moderators of group and public conversations.
- [ ] Set up 2 rooms, "Put in rooms by you": everyone but the moderators is listed with a room
      picker. Create: the card lists Room 1 and Room 2; the sidebar doesn't show them.
- [ ] Open a room from the card before starting: as moderator you're in; as someone else (the
      web app) the room is closed. In kvidr as a non-moderator, a room that isn't open says
      "… is a breakout room. It opens when a moderator starts the breakout rooms."
- [ ] **Start Breakout Rooms**: someone with the main conversation open in kvidr is moved into
      their room by itself (log: `Breakout rooms moved this session to another conversation`).
      If they were in the call, they're in the room's call.
- [ ] In the room: the bar says "Room 1 · <main conversation>", with **Ask for Help** and
      **Back to <main>**. Ask for Help: it turns into "Help Asked · Cancel".
- [ ] As moderator in the main conversation: the bar says "Room 1 asks for help" with **Go**, and
      the card shows "Asking for help" on Room 1. In the room, **Done** takes it down.
- [ ] Someone in the main conversation while rooms run (not moved automatically) sees "Breakout
      rooms are open · Go to Room 1".
- [ ] **Message All Rooms…**: the message appears in every room, in your name.
- [ ] **Move People…**: shows who is where now; move someone and they're in the other room.
- [ ] **Stop** (bar or card): everyone is moved back to the main conversation, and its call if
      they were in a room's call.
- [ ] Set up with "Choose a room themselves" and start: others get **Choose a Room** listing the
      rooms; choosing one opens it.
- [ ] **Delete Breakout Rooms…** asks first, then the card is back to Set Up.
- [ ] Unread messages in breakout rooms don't add to the Dock badge.

### Bots

Needs a bot installed on the server (an administrator runs `occ talk:bot:install`, or installs an
app that brings one, such as Call summary).

- [ ] As moderator: Inspector → Details → **Bots** lists the server's bots with a switch each,
      and its description under its name. Without bots on the server, there's no card.
- [ ] Turn one on: it answers in the chat as it's meant to (its messages marked BOT). Off: it
      stops. Reopen the inspector: the switches are as you left them.
- [ ] A bot the administrator set up for every conversation shows "Set up by your
      administrator", switched on and greyed out.
- [ ] Not a moderator: no Bots card.

### Raise hand, reactions and moderator mute

Talk's own call messages, so the web app and the phone should agree with kvidr both ways.

- [x] In a call, a **React** button sits between Share and More. It opens **Raise Hand** and
      the server's emoji.
- [x] Raise Hand: the button turns white with a hand; a yellow "Your hand is raised · Lower"
      pill shows over the controls; your corner tile gets a yellow hand. The web app shows
      your hand up. ⇧⌘R does the same without opening anything.
- [x] Someone raises theirs in the web app: their tile (or big picture, or name when their
      video fills the window) gets the yellow hand, and "Anna raised their hand" shows under
      the header. Lowering takes it away.
- [x] Send an emoji: it floats up from the bottom left with "You", fading as it goes. The web
      app shows it from you. One sent from the web app floats up in kvidr with their name.
- [ ] Join a call where your hand is already up elsewhere… or raise it, then have someone join:
      they see your hand.
- [x] More → **People in the Call**: a panel lists you and everyone else, raised hands first in
      the order they went up, with microphone and camera state; speaking rings too.
- [ ] People is now a round button in the call's top-right corner (opposite minimize), not in
      More: white while the panel is open, a small yellow hand on it while someone's hand is
      up, ⇧⌘P toggles it. The panel hangs under it.
- [x] As moderator: **Mute** beside someone who's unmuted mutes them — the web app mutes itself
      and says a moderator did. Not a moderator: no Mute buttons. FAILED 2026-09-23 in a
      one-to-one with the phone: nothing happened. kvidr sent it as an ordinary call message;
      Talk's apps take a forced mute only as a signaling "control" (as the web app sends it).
      Fixed, both ways. Test again with the phone, and from the web app to kvidr.
      FAILED AGAIN 2026-09-23 with the web app's own format: Talk for iOS drops a control whose
      data has no `type`, and reads `action`/`peerId` from the data's top level. Now sent as a
      control with data `{type: control, action: forceMute, peerId}` — which the web app reads
      too. The log says `Call: muting …, told to n session(s)` when it goes out. Passed
      2026-09-23 with the phone (it says "myrdet" — Talk for iOS's Danish for muted).
- [ ] A moderator mutes you from the web app: kvidr mutes, and says "A moderator muted you".
- [ ] While sharing your screen, the mini call's caption starts with ✋ when someone's hand is up.

### Small leftovers

- [ ] Right-click a message → Remind Me → **Custom…**: a calendar, and beside it a time field
      to type in (no clock face). Pick a day, type a time, Set Reminder: the message shows the
      reminder, and it goes off then. Changing the day keeps the time, and the other way round.
- [ ] Custom… won't set a time in the past: the time under the field turns red, and Set
      Reminder is greyed out.
- [x] Narrow sidebar with reminders set: a Reminders face at the top with the count; clicking it
      opens the Reminders list.
- [ ] Wide sidebar: the Reminders row's alarm lines up with the avatars' left edge below it, the
      name right beside it, and the count at the right like a sidebar count. The alarm stays
      orange when the row is selected. Catch Up's row looks the same way.
- [ ] The Reminders page reads like the Reminders app: "Reminders" large in orange with the
      count opposite, then the reminders under "Today", "Tomorrow", "Monday 28 September"…,
      each with the conversation's picture, name, message, and the time with an orange alarm.
- [ ] Hovering a reminder lights it up and shows ✕ (without moving the time); right-click has
      Show Message and Remove Reminder. Clicking one opens the message.

### Call notes

Written from Live Captions' transcript, so captions have to be on during the call.

- [ ] In a call with Live Captions on, talk for a minute, then More → **Summarize Call So Far**:
      a notes panel over the stage says "Reading the call…", then shows points, "Decided" and
      "To do" (with names) when there were any. ✕ closes it; the call goes on.
- [ ] Hang up (yourself, or the other side): the end screen stays and writes the call notes
      under "The call has ended". A long call says "Reading part 1 of 3…" first.
- [ ] **Put in Chat**: the call screen closes and the notes are in the conversation's field as
      Markdown, headed "Call notes · <conversation> · <time>" — read over, then send.
- [ ] **Copy** copies the same.
- [ ] A call without captions, or with hardly anything said: no notes, and hanging up closes
      the call screen as before.

### Call window in a short window

- [ ] Make the window short (half the screen's height) during a one-to-one call with their
      camera off: the header, their picture and the controls all fit — the picture gets
      smaller rather than anything going off the top or bottom, and the minimize button stays
      clear of the traffic lights. The same while it's still ringing.
- [ ] With the chat open beside the call, the same.

### Refreshing when you come back (regression)

kvidr now does its catch-up refresh only when it comes to the front from another app — not on
every alert, sheet or window change inside kvidr, which raced changes you had just made.

- [ ] Switch to another app, have the phone send a message, switch back: the sidebar and the
      open conversation catch up as before.
- [ ] Open Settings (its own window) and go back to the main window: what's on screen is
      marked read as before.
- [ ] Your status changed on the phone shows when kvidr comes to the front, as before.

### Siri, Shortcuts, Spotlight and Raycast

Spotlight search and Raycast passed 2026-09-23. Still open: Shortcuts, Siri, the `kvidr://`
links and sign-out clearing Spotlight.

- [ ] Shortcuts app → new shortcut → search "kvidr": **Send Message**, **Open Conversation**,
      **Call or Join Call**, **Catch Up**. The conversation picker lists your recent ones and
      finds others by name.
- [ ] Run **Send Message** from Shortcuts with kvidr quit: kvidr starts, the message is sent,
      and Shortcuts says "Sent to …".
- [ ] Siri in Danish (or type to Siri): "Send en besked med kvidr" asks to whom and what.
      "Hvad er nyt i kvidr" (or "Hvad er der sket i kvidr") opens the catch-up page. "Ring til
      Anna med kvidr" calls; "Åbn Anna i kvidr" opens. Siri may need a minute, or a relaunch of
      kvidr, to learn the new phrases.
- [ ] The alternative Danish phrases work too (they were lost when Xcode reorganised the
      phrase catalog, and are back): "Hvad er der sket i kvidr", "Vis Anna i kvidr",
      "Skriv til Anna med kvidr", "Deltag i opkaldet i Anna med kvidr".
- [x] Spotlight: type a conversation's name — it's there, under kvidr, with its last message
      (not for sensitive conversations). Picking it opens it in kvidr.
- [ ] Links: `open "kvidr://open?conversation=Anna"` in Terminal opens it;
      `kvidr://compose?conversation=Anna&text=Hi` opens it with "Hi" in the field, not sent;
      `kvidr://catch-up`; `kvidr://search?q=budget` filters the sidebar. A link clicked while
      kvidr is still starting still lands.
- [x] Raycast: add `Integrations/Raycast` under Script Commands (see its README). **Open
      Conversation**, **Write Message**, **Catch Up**, **Find Conversation** work, with ø and
      & in names.
- [ ] Sign out: the conversations are gone from Spotlight.

### Danish localization

kvidr's own text is now in `Kvidr/Resources/Localizable.xcstrings`, translated into Danish,
alongside the privacy prompts (`InfoPlist.xcstrings`). On a Mac whose first language is Dansk,
all of kvidr should be Danish, macOS's own menus and panels included. To switch kvidr alone:
System Settings → General → Language & Region → Applications → + → kvidr → Dansk (or English),
then quit and reopen kvidr.

Read it as a Danish user would. Anything English, stiff, cut off or wrong is a finding. Note
where it was (and paste the string) so the catalog can be fixed.

- [ ] Menu bar: kvidr's own items (New Message, Conversation, Call, View…) are Danish, next to
      macOS's own Danish ones (Rediger, Vindue), and read as one language. Shortcuts as before.
- [ ] Sidebar: search field, Favourites, Archive, Reminders and Catch Up rows, account bar, the
      "no conversations" and filter texts, times ("I går", weekdays), unread counts.
- [ ] Right-click a conversation: every item and submenu (Tags, Notifications with Important
      and Sensitive, and their grey subtitles) is Danish.
- [ ] Chat: date separators ("I dag", "I går"), "Nye beskeder", system lines kvidr writes itself,
      typing ("Anna skriver…", "Anna og Bo skriver…"), message right-click menu and Tapback,
      reply/edit bars, failed-send text, pinned message, threads, polls ("1 stemme" /
      "2 stemmer"), lobby.
- [ ] Composer: placeholder, attachment menu and tray (file sizes with a decimal comma),
      voice recording bar, scheduling and reminders ("I morgen", "Næste uge", Custom… sheet).
- [ ] Inspector and conversation settings: tabs, participant roles, "3 deltagere" style counts
      (one and many), sharing and moderation settings, bots, breakout rooms.
- [ ] Calls: ringing, "Ringer op…", "Forbinder…", the controls' help tags, More menu (devices,
      captions, summarize), the end screen and call notes, screen-share picker, minimized call,
      incoming-call notification and its buttons.
- [ ] Settings (every tab), Keyboard Shortcuts window, command palette (search with a Danish
      word, e.g. "ny besked", finds New Message; English aliases still work).
- [ ] Sign-in window and its errors (wrong address, no HTTPS), and sign-out confirmation.
- [ ] Notifications: a new message and a mention show Danish category actions (Svar, Marker som
      læst…).
- [ ] Errors: turn off Wi-Fi and send: the offline text is Danish.
- [ ] Apple Intelligence: summary, catch-up, smart replies, Ask: the buttons and states are
      Danish; the summaries themselves follow the conversation's language. Catch Up on a
      Danish conversation: "For you" and the dates are Danish too (they could come out in
      English before; the model is now told to write all of it in the messages' language).
- [ ] Privacy prompts, the first time (Terminal: `tccutil reset Microphone app.kvidr.mac`, and
      Camera, SpeechRecognition): the prompt's explanation is Danish.
- [ ] Shortcuts app: kvidr's actions, their parameters and results ("Sendt til …") are Danish.
- [ ] Switch kvidr to English: everything is back to English as before (nothing lost or
      changed), including the plurals ("1 person", "2 people").

### Call joins and leaves on one line

Consecutive "joined the call" / "left the call" events now share one line, like Talk's web
client: "Anna and Bo joined and left the call". The same goes for one person adding (or
removing) several people in a row: "Anna added Bo and Carl".

- [ ] A group conversation with a finished call of 2+ people: between "started a call" and
      the call-ended line there is one grey line with a chevron, not one per join and leave.
- [ ] Click it: the chevron turns and the single events appear under it, each with its time
      on hover. Click again and they fold away. Hovering the summary shows the time span.
- [ ] You were in the call: the line starts with "You" ("Du" in Danish), never your own name.
- [ ] A call with 4+ people: "Anna, Bo and 3 others joined and left the call".
- [ ] One join alone (someone joined, then someone wrote a message) stays an ordinary line.
- [ ] During a live call, watch the transcript as people join: the line updates in place
      without the transcript jumping, and an opened line stays open.
- [ ] Add two people to a group in one go: "You added Bo and Carl". Someone else adding a
      third right after gets their own line.
- [ ] The "New messages" marker in the middle of a call's joins splits the line in two,
      with the marker between them.
- [ ] VoiceOver: the line reads the summary, then "collapsed" or "expanded", and says what
      pressing it does.
- [ ] In Danish: "Anna og Bo kom og gik i opkaldet", "Anna, Bo og 3 andre …".

---

## Passed

Earlier features were tested before this file existed.

### Writing Tools — passed 2026-09-23

- [x] The message field has no white slab behind the text — the capsule's glass shows through,
      empty, while typing, and while Writing Tools works on it.
- [x] Write something in the composer, then + → **Writing Tools**: Apple's panel opens on it
      (Proofread, Rewrite, Friendly, …). Right-clicking the field has Writing Tools too.
- [x] Rewrite: the new text replaces the draft as plain text — no lists or tables forced in.
- [x] While Writing Tools is still working in the field, Return doesn't send.
- [x] With the field empty, the menu item is greyed out.

### Translating messages — passed 2026-09-23

On this Mac, with Apple's Translation framework — your server has no translation provider.
The translation shows inside the bubble, under the original, as Messages does it.

- [x] Right-click a message in another language → **Translate**. "Translating…" shows briefly,
      then the translation under a hairline, and "Translated from English" (in your Mac's
      language names) under it.
- [x] The first time for a language, macOS asks to download it. Download: the translation
      appears. Cancel: "… wasn’t downloaded for translation", and it doesn't ask again this
      session for that language.
- [x] Right-click the same message → **Show Original**: the translation goes.
- [x] Translate a message already in your language: "This is already in Dansk."
- [x] Pictures, polls and system lines have no Translate item.
- [x] Toolbar Apple Intelligence menu → **Translate Automatically**: other people's messages
      that aren't in your language get translated as they come on screen, new ones included.
      Short ones ("ok", "haha") and your own are left alone. It's remembered per conversation.
- [x] With Translate Automatically on, Show Original on one message keeps it untranslated.
- [x] The Apple Intelligence menu is there even on a Mac without Apple Intelligence, holding
      only Translate Automatically.
- [x] Settings → Translation → Translate into: pick English, and translate a Danish message
      into English. What was translated before is put away.

### Live Text in pictures — passed 2026-09-23

- [x] Open a picture with text in it (a screenshot, a sign): drag across words to select them,
      ⌘C copies. The Live Text button in the picture's corner highlights all the text.
- [x] A phone number, link or address in the picture can be clicked, as in Preview.
- [x] A QR code in a picture can be opened.
- [x] Clicking outside the picture still closes the viewer; Escape too.

### Genmoji — passed 2026-09-23

- [x] In the composer, open the emoji picker (the smiley, or Fn/🌐 E) — it offers to make a
      Genmoji. Make one and pick it: it's attached as a picture (named after what it shows) in
      the tray over the field, not put in the text.
- [x] Send with some words: the Genmoji goes as a picture with the words as its caption. The web
      app and the phone show the picture.
- [x] An existing Genmoji from the picker's recents attaches the same way.

### Summaries in more places — passed 2026-09-23

- [x] Open a thread → Apple Intelligence menu → **Summarize Thread**: a summary of the whole
      thread shows over it, headed "Summary of the thread “…”".
- [x] Apple Intelligence menu → **Summarize More** → **Last 24 Hours** / **Last Week**. On a busy
      conversation it says "Reading part 1 of 4…" and so on, then writes the summary.
- [x] A day with nothing said: "There’s nothing here to summarize."
- [x] A voice message longer than about a minute: **Summarize** under its transcript puts a
      sentence or two above it, marked with the Apple Intelligence symbol. Scroll away and back:
      it's still there.

### Ask a conversation — passed 2026-09-23

- [x] Apple Intelligence menu → **Ask This Conversation…** (⌥⌘A): a field over the chat,
      focused. Ask "What did Anna say about the invoice?" and press Return.
- [x] A short answer in the question's language, with chips for the messages it rests on
      ("Anna, 3 Sep"). Clicking one scrolls to that message and highlights it — even an old
      one Nextcloud's search found.
- [x] Ask about something that was never said: it says it can't find it, rather than making
      something up.
- [x] Escape or ✕ closes it.

### Dates and to-dos into Calendar and Reminders — passed 2026-09-23

- [x] Right-click a message that says a day and a time ("Shall we meet Thursday at 10 in the
      office?") → **Add to Calendar…**: a sheet reads the message, then shows a title
      ("Meeting in the office"), Thursday 10:00, an hour, and the place. Change anything, Add:
      macOS asks once for Calendar access; the event is in Calendar, with the message in its
      notes and a link back.
- [x] A message without a date has no Add to Calendar — only **Add to Reminders…**.
- [x] Add to Reminders on "Can you send me the draft by Friday?": the title reads like a to-do
      ("Send the draft"), due Friday. Turn "Remind me on a day" off for one with no date. macOS
      asks once for Reminders access.
- [x] Without Apple Intelligence: the sheets still work, titled with the message's first words.
- [x] Refusing access: the sheet says where in System Settings to allow it.

### Catch-up digest — passed 2026-09-23

- [x] With two or more conversations unread, a **Catch Up** row sits at the top of the sidebar
      with the count. Apple Intelligence menu → **Catch Up on Everything** opens the same page.
- [x] The page reads the conversations one after another ("Reading…"), then shows for each: a
      sentence or two, **For you** (questions and requests at you, with who asked), **Dates**,
      and "Needs an answer" on the ones that do. Those move to the top.
- [x] Nothing is marked as read: the unread counts in the sidebar stay as they were.
- [x] Clicking a card opens that conversation. **Refresh** reads again.
- [x] With nothing unread: "All Caught Up".

### Smart replies — passed 2026-09-23

- [x] Someone sends you a message: three short suggested replies appear over the field, in the
      conversation's language, marked with the Apple Intelligence symbol.
- [x] Click one: it goes into the field (not sent), ready to send or change.
- [x] Start typing: they go. Your own message last, or the last message a day old: none.
- [x] In an open thread, they answer the thread's last message.
- [x] Settings → Messages → **Suggest replies** off: none anywhere.

### Live poll results and live status — passed 2026-09-23

- [x] A poll with public results, open in kvidr: someone votes in the web app — kvidr's card
      updates within a few seconds, without reopening the conversation.
- [x] Someone closes the poll in the web app: kvidr's card shows it closed, with results.
- [x] Change your own status on the phone or in the browser, then bring kvidr to the front:
      the sidebar's status dot and Settings show the new one. Left in front, it catches up
      within two minutes.
- [x] Someone you have a one-to-one with goes Away or Do Not Disturb: their dot and status
      message in the sidebar follow — at once when kvidr comes to the front, within two minutes
      otherwise.

### Menus that don't blink — passed 2026-09-23

Every menu with a submenu is now built by AppKit when it opens, as the thread bar's and a
message's already were: SwiftUI rebuilt its menus with each redraw, and open submenus blinked.

- [x] Toolbar Apple Intelligence menu → hover **Summarize More** and leave it open a minute
      (let a message arrive): it stays put. Each item still works; ⌥⌘S and ⌥⌘A still work
      without opening it (⌥⌘A is now in the menu bar's Conversation menu too).
- [x] Composer **+** → **Translate**: the language list stays put. Photos…, Files… (⇧⌘A too,
      without opening the menu), Poll…, New Thread, Writing Tools, Send Later all work, and
      the menu opens right under the +. The same + in a new message's draft.
- [x] Right-click a conversation row → **Tags** and **Notifications**: they stay put while the
      sidebar refreshes. The row gets an accent outline while its menu is open. Left clicks
      still select; the narrow sidebar's faces behave the same.
- [x] Right-click a scheduled message → **Change Time**: it stays put.
- [x] In a call, **More** → **Captions → Language** stays put; every item (People, Summarize,
      Live Captions, camera, microphone, speaker) still works, ticks where they should be.

### Account bar in the sidebar — passed 2026-09-23

- [x] Scroll the sidebar so conversations pass under your name at the bottom: they go behind a
      solid bar, never through the name.

### Translate before sending — passed 2026-09-23

Reworked after the first test: it translates when you pick a language, not on Return.

- [x] Write in Danish, then + → **Translate** → English: the draft turns into English, and a
      capsule in the field says "Translated into English" with **Show Original**. Return sends
      as always.
- [x] Select a few words in the draft: the item says **Translate Selection**, and only those
      words are translated, the rest left as written.
- [x] **Show Original** puts back the draft as it was before the first translation. The ✕ closes
      the capsule and keeps the translation.
- [x] The language used last in a conversation is first in the menu there next time.
- [x] Translating something already in that language: "This is already in English."
- [x] With the field empty, **Translate** is greyed out.

### Conversation tags — passed 2026-09-23

Your own groups in the sidebar — Talk's "conversation tags", the same ones the web app shows.

First run failed both ways. Fixed: New Tag's Create did nothing (the alert cleared the name
before Create read it), and a tagged favourite only showed among the faces. The log now says
`Conversation tags: n of your own` on every full refresh, and `Made the tag …`, or why not.
A tag with no conversations in it shows no section, in kvidr and in the web app alike.

- [x] New Tag… → Create: the section appears at once with the conversation in it, before the
      server has answered, and stays. If the server refuses, it goes again (the log says why).
- [x] Tick an existing tag on a conversation: it moves into the section at once and stays —
      it no longer waits for the next tagging to show up. (Was: a list refresh started as the
      New Tag box closed put the old state back.)
- [x] A tag made on the iPhone (Talk for iOS has tags too) shows in kvidr when kvidr comes to
      the front, with its conversations. The log line lists how many conversations are in tags.

- [x] Right-click a conversation → **Tags** → **New Tag…**, name it "Work": a **Work** section
      appears between the favourite faces and the rest, with the conversation in it, and the
      rest now under Talk's heading for them.
- [x] Right-click another → Tags → tick **Work**: it moves into the section. Untick: back.
- [x] Give one conversation two tags: it shows in both sections.
- [x] A favourite with a tag is in both places, as in the web app: among the faces, and in
      its tag's section.
- [x] Click a section's heading: it folds (chevron turns), and says how many are tucked away.
      Folded, unread conversations and the open one still show. The web app shows it folded
      too.
- [x] Right-click a heading: **Rename…**, **Move Up**, **Move Down**, **New Tag…**,
      **Delete Tag…**. Each does what it says, and the web app agrees after a reload.
- [x] Delete a tag: it asks first; its conversations go back among the rest.
- [x] Tags made in the web app show in kvidr after the next full refresh (or relaunch).
- [x] Quit and relaunch: the sidebar opens already grouped.
- [x] The narrow sidebar shows each face once.
- [x] While searching (⌘F), results are one flat list as before.

### Talking indicators — passed 2026-09-23

A white ring, with a faint glow, around whoever is talking. It comes on at the first word and
fades about a second after they stop, so the pauses between words don't make it blink.

- [x] Call your phone. Talk on the phone: their tile — or their big picture, with their camera
      off — rings. Stop talking: it fades about a second later.
- [x] Talk into the Mac's microphone: your own corner tile rings.
- [x] Mute: your ring goes out at once, and stays out while you're muted.
- [x] Turn the camera on and off on both ends: the ring sits on the video tile the same way.
- [x] Share your screen: the two tiles in the floating mini call ring too.
- [x] One-to-one with their video filling the window: no ring, on purpose.
- [x] Talk's own app, on the phone, shows kvidr as speaking when you talk.
- [x] If nothing rings: the log says `Call: hearing this Mac's own level` and
      `Call: hearing levels from …`. If those lines are missing, WebRTC isn't reporting levels.
