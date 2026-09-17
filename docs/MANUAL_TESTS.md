# Manual tests

What to click, and what should happen, for the parts of kvidr no compiler and no unit test
can check. Written to be worked through on a dev machine with a real Nextcloud behind it.

`swift test` covers the rules underneath most of this — date phrases, suggestion shapes,
return times, triage scoring. What is listed here is everything those tests cannot see: the
drawing, the timing, the permissions, and whether the thing is any good.

## How to use this

Each section is one feature: what has to be true before you start, the steps, and what
should happen. **Bold** lines are the ones that matter most — if only one thing gets tested,
test those.

Two switches change nearly everything below, so know where they are:

- **System Settings → Apple Intelligence & Siri** — on or off.
- **kvidr → Settings → Intelligence** — the per-feature switches, and where reminders go.

A good half of the work here is checking the app is still sensible with Apple Intelligence
**off**. That is not an edge case: it is every Intel Mac, every Mac in a region where it
hasn't shipped, and everyone who turned it off on purpose.

### Setting up a second account

Most of this needs somebody to talk to. The quickest way is a second user on the same
Nextcloud, signed in on your phone or in a private browser window, in a one-to-one with
your own account.

---

## 1. Times you type become reminders

*Shipped 17 September 2026. Design: `plans/2026-09-17-apple-intelligence-design.md`.*

**Precondition:** Settings → Intelligence → "Underline times you type" on. Works with Apple
Intelligence on or off — do the first pass with it **off**, so you are testing the table.

| # | Do this | Expect |
| --- | --- | --- |
| 1.1 | Type `lad os snakke om det i morgen` in the message field | **`i morgen` is blue and underlined. Nothing else is.** |
| 1.2 | Click the underlined words | **A dashed pill appears in the field: "Remind me Tomorrow 09:00", with the phrase beside it** |
| 1.3 | Press Return | The message sends; right-click it — it has a reminder on it, and the orange alarm line shows under the bubble |
| 1.4 | Open Reminders in the sidebar | The reminder is listed, for tomorrow 09:00 |
| 1.5 | Type the sentence again, click the phrase, then click the pill's × | The pill goes; sending sets no reminder |
| 1.6 | Type `mødet er i morgen kl. 14` | The underline covers **all** of `i morgen kl. 14`, and the pill says 14:00 — not two underlines, not 09:00 |
| 1.7 | Type `der er 14 tilmeldte` | **Nothing is underlined.** A bare number is not a time |
| 1.8 | Type `lad os snakke om det` | Nothing is underlined |
| 1.9 | Type `👍 i morgen` | The underline is under `i morgen`, not shifted one character right |
| 1.10 | Type a sentence, then insert words *before* the phrase | The underline moves with its words as you type |
| 1.11 | Put the caret just after an underlined phrase and keep typing | **The new text is normal colour, not blue** |
| 1.12 | Double-click an underlined phrase | It selects the word, as in any text field — it does not fire the reminder twice |
| 1.13 | Try `på fredag`, `om et par dage`, `i overmorgen`, `next week`, `in two hours`, `tomorrow at 2pm` | Each is underlined and resolves sensibly |

**With Apple Intelligence on**, additionally:

| # | Do this | Expect |
| --- | --- | --- |
| 1.14 | Type `lad os tage det på fredag efter frokost` and wait about a second | `på fredag efter frokost` underlined, resolving to Friday early afternoon |
| 1.15 | Type quickly for ten seconds without pausing | No stutter in the field. The underline keeps up; nothing flickers |

### Composer height — the risky one

`updateHeight()` changed text stacks in this work. Check it directly:

| # | Do this | Expect |
| --- | --- | --- |
| 1.16 | Type until the field wraps to 2, 3, 4 lines | **It grows line by line, smoothly** |
| 1.17 | Keep going past six or seven lines | It stops growing and starts scrolling instead |
| 1.18 | Delete back down to one line | It shrinks back; the transcript above does not jump |
| 1.19 | Select some text, right-click → Writing Tools → Proofread | **Writing Tools opens and can change the text in place** |

---

## 2. One-tap suggestions under a message

**Precondition:** Settings → Intelligence → "Suggest what to do with a message" on. Works
with Apple Intelligence off.

| # | Do this | Expect |
| --- | --- | --- |
| 2.1 | From the other account, send `Kan vi tales ved i morgen?` | **An "Add to Reminders" chip appears under that message** |
| 2.2 | Click it | It becomes "Reminder set" and stops being clickable. The reminder is in the Reminders list |
| 2.3 | Scroll away and back | It still says "Reminder set" |
| 2.4 | From the other account, send a list: `Vi skal bruge:` then `- chips` `- tomater` `- ananas` on their own lines | **An "Add to Notes" chip appears** |
| 2.5 | Click it | It becomes "Added to Notes". Open Note to self — the text is there, credited to the sender, with the conversation named |
| 2.6 | Send `Vi skal bruge: chips, tomater, ananas, sodavand` on one line | Add to Notes appears — the inline list counts |
| 2.7 | Send `Husk i morgen: chips, tomater, ananas, sodavand` | **Both chips appear** |
| 2.8 | Send `ja, det lyder fint` | **No chips.** Ordinary chat gets none |
| 2.9 | Scroll far up the conversation | No chips on old messages — only the newest handful carry them |
| 2.10 | Send a message yourself that names a time | No chips on your own messages (except in Note to self) |
| 2.11 | Mark a conversation sensitive in Nextcloud, repeat 2.1 | **No chips at all in that conversation** |
| 2.12 | Turn the setting off in Settings, reopen the conversation | No chips anywhere |
| 2.13 | Hover a chip | The tooltip names the phrase it read and the time it resolved to |

---

## 3. Suggested replies

**Precondition:** Apple Intelligence **on**; Settings → Intelligence → "Suggest replies" on.

| # | Do this | Expect |
| --- | --- | --- |
| 3.1 | From the other account, send `Kan du nå at kigge på rapporten i dag?` | **Two or three reply chips appear above the message field, within a second or two** |
| 3.2 | Read them | **They are in Danish** — the language the question was asked in |
| 3.3 | Click one | It goes **into the field**, with the caret after it. Nothing is sent |
| 3.4 | Press Return | It sends as an ordinary message |
| 3.5 | Have them send another message, then start typing yourself | The chips disappear as soon as you type |
| 3.6 | Start a reply (⇧⌘R), then look | No chips while a reply is being composed |
| 3.7 | Send a message yourself so you spoke last | No chips — there is nothing to answer |
| 3.8 | Read the suggestions over a few conversations | **None of them invents a commitment** — no "I'll send it at 2", no prices, no dates you didn't agree to |
| 3.9 | Switch Apple Intelligence off in System Settings, reopen kvidr | **No reply chips at all, and no empty space where they were.** Everything in §1 and §2 still works |
| 3.10 | Open Settings → Intelligence with it off | A line explains why, and says the rest still works |

---

## 4. Where reminders go

**Precondition:** Settings → Intelligence → "Reminders go to".

| # | Do this | Expect |
| --- | --- | --- |
| 4.1 | Leave it on **Nextcloud**. Right-click a message → Remind Me → In 1 Hour | The reminder appears in kvidr's Reminders list, and in Talk on your phone |
| 4.2 | Switch to **Apple Reminders**. Set another reminder | **macOS asks for permission to your reminders, once** |
| 4.3 | Allow it, open Reminders.app | The reminder is in the default list, titled `Sender: the message`, with an alarm at the time |
| 4.4 | Check kvidr's Reminders list | It is **not** there — you chose Apple |
| 4.5 | Switch to **Both**, set another | It is in both places |
| 4.6 | Refuse permission at step 4.2 instead, then open Settings → Intelligence | An orange line explains, and points at System Settings |
| 4.7 | With a sensitive conversation, set an Apple reminder | **The message text is not in Reminders.app** — only that there is one |
| 4.8 | On a server too old for `remind-me-later`, with Apple chosen | Remind Me still works, going to Apple |

If 4.2 never prompts and nothing appears, the signed build is missing either the
`com.apple.security.personal-information.calendars` entitlement or
`NSRemindersFullAccessUsageDescription`.

---

## 5. Send Later, when they are away

*No model involved — this is the server's own out-of-office data.*

**Precondition:** a one-to-one with somebody who has set an out-of-office in Nextcloud
(Settings → Availability → Absence) that is **current**, and a server supporting scheduled
messages.

| # | Do this | Expect |
| --- | --- | --- |
| 5.1 | Open the one-to-one. The out-of-office bar shows at the top | As before this work — unchanged |
| 5.2 | Type anything | **A bar appears over the field: "Heine is away until Fri 19 Sep · Send Mon 22 Sep 08:00"** |
| 5.3 | Click the Send… link | Send Later's dashed pill appears in the field, already set to that morning |
| 5.4 | Press Return | It is scheduled, not sent — it appears at the foot of the conversation in outline |
| 5.5 | Set their absence to end on a **Friday**, reopen | **The suggestion says Monday morning, not Saturday** |
| 5.6 | Click the bar's × | It goes, and stays gone for this conversation. Return sends normally |
| 5.7 | Switch conversation and come back | The suggestion is offered again |
| 5.8 | Clear the draft | The bar goes with it — there is nothing to hold |
| 5.9 | Stage a file, type a caption | No suggestion: files cannot be scheduled |
| 5.10 | Open the + menu → Send Later | **"When Heine is back — Mon 08:00" is the first item, above the usual times** |
| 5.11 | In a conversation with nobody away, open the same menu | Only the usual times. No absence item |
| 5.12 | With an absence that ends **today** | No suggestion — the morning after has already been |

---

## 6. Catch up on what you missed

**Precondition:** Apple Intelligence **on**; Settings → Intelligence → "Offer to catch you
up" on. You need a conversation with at least six unread messages from somebody else — the
easiest way is to leave kvidr on another conversation while the second account sends a
dozen.

| # | Do this | Expect |
| --- | --- | --- |
| 6.1 | Open the conversation with the unread pile | The "New messages" line reads **"Catch me up on 12"** instead of "New messages" |
| 6.2 | Do nothing for a minute | **Nothing is summarised.** No spinner, no inference, until you ask |
| 6.3 | Click it | The line says "Catching you up…", then a card appears **under the line, above the unread messages** |
| 6.4 | Read the card | A headline, two to four bullets, and a grey caption saying how many messages it read and that it happened on this Mac |
| 6.5 | Check it against the messages themselves | **It names who said what, and invents nothing.** This is the one to be fussy about |
| 6.6 | If somebody asked you something directly | An orange "Needs you" tag on the card |
| 6.7 | Click the card's × | The card goes; the line goes back to offering |
| 6.8 | Switch to another conversation and back | The summary is not carried over into the other room |
| 6.9 | Open a conversation with 3 unread | **No offer** — reading three is quicker than summarising them |
| 6.10 | Open one with no unread | The line isn't there at all, as before |
| 6.11 | In a sensitive conversation with unread | **No offer** |
| 6.12 | Turn the setting off | The line reads "New messages" again, everywhere |
| 6.13 | With Apple Intelligence off | The line reads "New messages" — no offer, no empty button |
| 6.14 | Have a Danish conversation | **The summary is in Danish** |
| 6.15 | Click, then immediately switch conversations | No summary lands in the wrong room |

The card must never be mistakable for a message: no bubble, no avatar, a sparkles symbol and
a caption. If it reads as something somebody said, that is a bug worth stopping for.

---

## 7. What needs you, in the sidebar

**Precondition:** Settings → Intelligence → "Mark what needs you" on. The first half works
with Apple Intelligence off — check it that way first.

| # | Do this | Expect |
| --- | --- | --- |
| 7.1 | From the other account, send `Kan du nå at kigge på rapporten inden fredag?` to a conversation you are not looking at | **An orange `?` appears on that row in the sidebar, immediately** |
| 7.2 | Open that conversation | The orange mark goes at once — not on the next sync |
| 7.3 | Have them send `ok, tak!` to another conversation | **No mark.** An acknowledgement is not a question |
| 7.4 | Have them send `👍` | No mark |
| 7.5 | Have them send `Husk at få den godkendt` (no question mark) | Marked — a plain request counts |
| 7.6 | Have them `@mention` you | The `@` badge shows, as before, and takes precedence over the orange `?` |
| 7.7 | Send something to yourself in Note to self | No mark — your own message can't be waiting on you |
| 7.8 | Look at a sensitive conversation with unread | **No mark** |
| 7.9 | Turn the setting off | Every orange mark goes |
| 7.10 | With Apple Intelligence off, repeat 7.1 and 7.3 | Both still behave — those are the table's, not the model's |

**With Apple Intelligence on**, the ambiguous ones get a second opinion:

| # | Do this | Expect |
| --- | --- | --- |
| 7.11 | Have them send `jeg har lagt den i mappen` | Probably no mark — it is an announcement |
| 7.12 | Have them send `jeg mangler stadig dit input på den her inden vi sender` | Marked — somebody is blocked on you |
| 7.13 | In a **group**, have them ask somebody else a question by name | Ideally no mark. Worth watching over a few days: a marker that fires on everything is worse than none |
| 7.14 | Watch Activity Monitor while a sync brings in twenty conversations | **One burst of work, not twenty** — the whole sidebar is one question |

---

## 8. A rush of notifications becomes one

**Precondition:** Settings → Notifications → "Group a rush of notifications" on, and
notifications allowed by macOS. Have kvidr in the background — banners only show when the
window isn't front.

The burst has to be **three different conversations within eight seconds**, so you need the
second account posting to three rooms quickly, or a colleague's help.

| # | Do this | Expect |
| --- | --- | --- |
| 8.1 | Have one message arrive in one conversation | **A normal banner, instantly.** Nothing is delayed or grouped |
| 8.2 | Have five messages arrive in the *same* conversation | Normal banners, threaded by macOS as before — one room is not a burst |
| 8.3 | Have messages land in three different conversations within a few seconds | **The individual banners are taken back and one replaces them: "3 conversations are waiting"** |
| 8.4 | Read the body with Apple Intelligence **off** | The names: "Heine, Salina and Jay" |
| 8.5 | With Apple Intelligence **on**, watch the same banner for a second | It updates in place to a sentence — "Heine needs the invoice; Salina asked about Friday" |
| 8.6 | Check the wording | One sentence, not cut off mid-way, in the conversation's language |
| 8.7 | Click the digest banner | kvidr comes forward |
| 8.8 | Have somebody **@mention** you during a burst | **That one gets its own banner anyway** — a mention is never swallowed |
| 8.9 | Include a sensitive conversation in the burst | Its words are not in the digest |
| 8.10 | Open a conversation after a digest | The digest banner is taken off screen |
| 8.11 | Turn the setting off, repeat 8.3 | Three separate banners, as before |
| 8.12 | Turn notifications off entirely | Nothing, as before |

If a digest appears when only one or two conversations were involved, or an ordinary single
message is ever late, that is a bug — the whole point is that the common case is untouched.

---
