# Apple Intelligence — design

*17 September 2026. Times you name become reminders, messages offer what to do with them,
and replies are suggested — the Messages features from iOS 27, built for a Nextcloud Talk
client on macOS 26.*

## 0. The rule everything else follows

**Nothing here is allowed to need Apple Intelligence.**

kvidr runs on Macs that don't have it, for people who switched it off, in countries where
it hasn't shipped. So each feature is built in two layers:

| Layer | Where | Needs a model? |
| --- | --- | --- |
| A table — phrases, list shapes, rules | `Sources/TalkCore/Intelligence/` | No. Unit-tested, offline, instant. |
| The on-device model, adding what a table can't hold | `Kvidr/Features/Intelligence/` | Yes, and only ever *adds*. |

The table answers on the same turn as the keystroke. The model answers a few hundred
milliseconds later, if it is there. A Mac without Apple Intelligence loses the long tail,
never the feature — with one exception, suggested replies, which is nothing *but* a model
and is hidden when there isn't one.

Nothing leaves the Mac. `SystemLanguageModel.default` only, never Private Cloud Compute: a
work chat is exactly the content you don't send anywhere, and a client that quietly posted
your colleagues' messages to a server for a nicer suggestion would deserve everything it
got.

## 1. Times, underlined where you typed them

Typing `lad os snakke om det i morgen` underlines **i morgen** in link blue. Clicking it
arms a reminder; a pill appears in the field, where Send Later's does, saying
"Remind me Tomorrow 09:00". Sending the message sets the reminder. Cancelling the pill, or
sending something else, sets nothing.

### Why not `NSDataDetector`

Because it is built around English. `i morgen`, `på fredag`, `om en uge`, `i overmorgen` —
the phrases this app actually sees — go straight past it. `DateExpressionScanner` is a
tokenizer and a phrase table covering Danish and English:

- days: `i dag`, `i morgen`, `i overmorgen`, `i aften`, `i nat`, `idag`/`imorgen`
- weekdays, with or without a leading word: `på fredag`, `næste mandag`, `on friday`
- weeks and months: `næste uge`, `næste måned`, `next week`
- stretches: `om en time`, `om 30 minutter`, `om et par dage`, `in two hours`
- clock times: `kl. 14`, `kl 14.30`, `klokken 15`, `at 2pm`, `14:00`
- parts of the day, which join a day: `i morgen tidlig`, `friday morning`, `efter frokost`

A day and a time next to each other are read as **one** phrase, so `i morgen kl. 14` is one
underline and one suggestion. Anything already in the past is dropped. Ranges are counted in
`Character`s, not UTF-16 units, so an emoji earlier in the line doesn't shift the underline.

It is deliberately shy. A bare number is not a time (`i morgen 5 personer` is tomorrow at
nine, not five o'clock); `om det` and `in a meeting` name nothing. A false underline under
an innocent word is worse than a missed phrase, because the underline is a claim.

### What the model adds

`OnDeviceIntelligence.refinedDates(in:alreadyFound:)` is asked, 450ms after typing stops,
for the phrases the table missed — `på fredag efter frokost`, `engang i næste uge`. Two
guards make its answer safe to draw:

1. **It is asked for words, never offsets.** The phrase it returns is then located with
   `range(of:)` in the real text. A model's character offset is a guess; `range(of:)` is not.
2. **Its answer is bounded.** Between now and a year out, 2–40 characters, non-overlapping
   with what the table already found, at most three.

Anything failing either guard is dropped silently. There is always a next keystroke.

### Why the reminder waits

Talk hangs a reminder on a **message id**, and a message being typed doesn't have one. So a
click arms an `ArmedReminder` — a date and the words that named it — and `ChatModel` sets
it in `transmit`'s success path, when the server hands back the real message. A send that
fails sets no reminder, which is the honest outcome: there is nothing to be reminded about.

## 2. The one-tap row under a message

`SuggestionScanner` offers at most two chips under a bubble:

- **Add to Reminders** — the message names a time that hasn't passed.
- **Add to Notes** — the message is a list: two or more bulleted or numbered lines, or a
  colon followed by three or more comma-separated items. ("Vi skal bruge: chips, tomater,
  ananas" — the case from Apple's own screenshot.)

Notes go to the **Note to self** conversation Talk already gives every user, credited to
whoever wrote them. No new storage, no new permission, and they are on your phone before
you have finished reading them.

Three rules keep the row from becoming furniture: chips appear only on the **newest eight**
messages (anything above that is history), never on your own words except in Note to self,
and never in a conversation marked sensitive. A chip that has been used says so and stops
being a button.

**No model runs per message, on purpose.** A chip that appears half a second after you have
read the message is worse than no chip, and a transcript that starts an inference for every
bubble that scrolls past is not a transcript anyone should ship. The chips are pure table,
which is also why they work with Apple Intelligence off.

## 3. Suggested replies

Two or three replies above the message field — where the mention list goes, since a Mac has
no keyboard row to put them in. Asked for only when there is something to answer: somebody
else spoke last, the field is empty, and no reply, edit or Send Later is in progress.
Clicking one puts it **in the field** rather than sending it. Nothing is ever sent by one
click.

The prompt carries the user's own last six messages as the example of how they write — the
"personalized writing style" idea — which is the difference between a suggestion they would
send and one that sounds like a brochure. The instructions forbid inventing a commitment: 
"Det kigger jeg på" is a reply; "Jeg sender den kl. 14" is a promise the app is not allowed
to make on somebody's behalf.

Sessions are thrown away when the conversation changes. One room's context is none of the
next room's business.

## 4. Writing Tools

One line: `textView.writingToolsBehavior = .complete` in `ComposerTextView`. Proofread,
Rewrite and the tone changes, in the field, from the system.

It came with a real change underneath it. `updateHeight()` used to read
`textView.layoutManager`, and reading that on a TextKit 2 view doesn't return nil — it drops
the whole view back to TextKit 1, where Writing Tools can only offer its limited experience.
So height is now measured from `textLayoutManager` when there is one, and the TextKit 1 path
is the fallback rather than the default. **Worth an eye on a Mac:** composer growth, wrapping
and the scroll ceiling all go through that measurement.

## 5. Where reminders go

Settings → Intelligence → "Reminders go to": **Nextcloud**, **Apple Reminders**, or
**Both**. Nextcloud is the default and the better answer for most people — it needs no
permission and follows you to Talk on every device. Apple Reminders is there because for a
lot of people the place they will actually look is the app in their Dock.

Every "remind me" in the app — the message menu, the chip, the armed pill — goes through
`ReminderStore.remind(about:at:)`, so the setting is honoured in one place rather than
three. Access to Reminders is asked for at the moment it is first needed, never at launch.
Sensitive conversations never have their words copied into another app's database.

On macOS, Reminders sits behind `com.apple.security.personal-information.calendars` —
there is no separate reminders entitlement — plus
`NSRemindersFullAccessUsageDescription`, both added. kvidr only ever **adds** a reminder;
it never reads the ones already there.

## 6. The eight that followed

*Added the same day, after the first slice landed.* Same rules: the table first, the model
only where a table can't go, nothing leaves the Mac, and nothing here is allowed to be the
only way to do something.

| # | Feature | Model needed? | Where |
| --- | --- | --- | --- |
| 1 | **Send Later when they're away** — "Heine is away until Friday · Send Mon 08:00" | **No.** The server already said they're away | `AbsenceSendLaterBar`, `Absence.firstMorningBack` |
| 2 | **Catch up** — four lines about what you missed, from the new-messages line | Yes, and asked for by a click | `CatchUpModel`, `CatchUpCard` |
| 3 | **Needs you** — an orange `?` on conversations waiting on you | Partly. Questions and requests are a table; the rest is one batched call | `AttentionScanner`, `AttentionModel` |
| 4 | **One banner for a rush** — three conversations at once become one notification | Partly. The names need no model; the sentence does | `NotificationDigest` |
| 5 | **Thread → poll** — fills the poll sheet's fields from the conversation | Yes | `OnDeviceIntelligence+Poll`, `NewPollSheet` |
| 6 | **⇧⌘F reads a question** — "hvad sagde Heine om fakturaen i sidste uge" | Partly. Keywords are a table; who and when need the model | `NaturalLanguageQuery`, `SearchIntent` |
| 7 | **What a long voice message came to** — a line and any to-dos, under the transcript | Yes | `VoiceInsightsModel` |
| 8 | **Translate a message** | **No** — Apple's `Translation` framework, a different thing entirely | `MessageTranslationModel` |

Three of the eight need no language model at all, and three more work at reduced strength
without one. That ratio is the point.

### Decisions worth keeping

- **A sidebar is one question, not twenty.** The triage in #3 sends every ambiguous
  conversation in a single prompt and gets back a list of *numbers*, which are then mapped
  to tokens here. A model never sees or returns an identifier the app trusts.
- **The common case is never made worse to serve the rare one.** #4 collapses a burst only
  once it is already happening: a single message still raises its banner instantly, with no
  buffering and no delay.
- **Nothing is summarised unasked, except where the cost is bounded.** #2 waits for a click.
  #7 doesn't, because it only reads transcripts over half a minute and voice messages are
  rare — and the transcript it reads was already written out automatically.
- **Say what you did.** #6 puts a bar under the search field naming what was actually
  searched, with "Use what I typed" one click away. Silently changing somebody's search is
  how a search box loses their trust for good.
- **The original stays.** #8 puts the translation *under* the message, never in place of it.

### What each one costs when the model is away

| Feature | With Apple Intelligence off |
| --- | --- |
| Send Later when away | Identical |
| Translate | Identical |
| Underlined times, one-tap chips | Identical but for the long-tail phrases |
| Needs you | Questions and plain requests still marked; the ambiguous ones aren't |
| One banner for a rush | Still one banner; it lists names instead of saying what they want |
| ⇧⌘F reads a question | Still strips the question words; no who/when narrowing |
| Catch up, thread → poll, voice gist, suggested replies | Not offered — the button or row simply isn't there |

## 7. What this is not

- **No cloud model, no Private Cloud Compute, no third-party provider.** The 2026
  `LanguageModel` protocol makes all three a few lines away; that is exactly why the line
  is drawn here in writing.
- **No summarising of a conversation, yet.** Catching up on 47 unread messages is the
  obvious next one, and it is a different design: it needs streaming, a place to put the
  result, and a clear "this is a summary" boundary in a transcript people trust.
- **No auto-send, ever.** Every suggestion in here ends with the user clicking send.

## 8. Files

```
Sources/TalkCore/Intelligence/
  DateExpression.swift        DateExpressionScanner — the table. Foundation only.
  MessageSuggestion.swift     SuggestionScanner — what a message is asking to become.
Tests/TalkCoreTests/
  DateExpressionScannerTests.swift   Fixed to Wed 17 Sep 2025, 10:00. 
  MessageSuggestionTests.swift
Kvidr/Features/Intelligence/
  OnDeviceIntelligence.swift  The only file that imports FoundationModels.
  ComposerIntelligence.swift  Table now, model a moment later. Plus ArmedReminder.
  SmartReplyModel.swift       When to ask, and what the model is told.
  IntelligenceViews.swift     The chips, the reply row, the armed pill.
Kvidr/Features/Chat/
  ChatModel+Suggestions.swift Eligibility, memoisation, and what a chip does.
Kvidr/Features/Reminders/
  AppleRemindersService.swift EventKit, and ReminderDestination.
```

And for the eight:

```
Sources/TalkCore/Intelligence/
  AttentionScanner.swift      Is this message waiting on you? (#3)
  SearchIntent.swift          NaturalLanguageQuery + SearchIntent (#6)
Sources/TalkCore/Models/
  Absence.swift               Moved here; firstMorningBack lives on it (#1)
Kvidr/Features/Intelligence/
  OnDeviceIntelligence.swift  answer(_:purpose:instructions:prompt:) — every question
  OnDeviceIntelligence+CatchUp / +Triage / +Digest / +Poll / +Search / +Voice
  CatchUpModel.swift, CatchUpCard.swift                     (#2)
  AttentionModel.swift                                      (#3)
  VoiceInsightsModel.swift                                  (#7)
  MessageTranslation.swift                                  (#8)
Kvidr/Features/Scheduled/AbsenceSendLaterBar.swift          (#1)
Kvidr/Notifications/NotificationDigest.swift                (#4)
```

Every question to the model goes through one `answer(_:purpose:instructions:prompt:)`, so a
guardrail trip, a context overflow and a model that went away mid-sentence all arrive as
`nil` and every caller keeps the path it already had. One session per purpose, so one
question's answer is never in the context of the next.
