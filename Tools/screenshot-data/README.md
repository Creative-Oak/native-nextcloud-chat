# Screenshot data

A throwaway Nextcloud with Talk, filled with a believable week at a small company, for
screenshots on the website and in the App Store. Nothing here touches the app: kvidr signs
in to it like any other server.

## Quick start

Needs Docker Desktop and Python 3. The Python that comes with Xcode's command-line tools is
enough; the script uses only the standard library.

```sh
cd Tools/screenshot-data
./setup.sh
```

That starts Nextcloud on <http://localhost:8080>, installs Talk, and downloads the stock
photos. It then creates twelve people and thirteen conversations, and **backdates** every
message, so the sidebar says "Yesterday" and "Tuesday" and the transcript has day
separators. Finally it keeps a call running in *Design crit*. **Leave that terminal open**
while you take screenshots, and press Ctrl-C when you're done.

Then in kvidr:

1. **Settings → Advanced → Allow insecure local servers** on. Plain HTTP is only ever
   allowed for localhost and private addresses.
2. Sign in to `http://localhost:8080`. The browser opens Nextcloud's login page: sign in
   as **`freja`** / **`kvidr-screenshots-2026`** and approve the app.

Don't join the call in *Design crit* from kvidr. The people in it are only the script
checking in for them, so there's no audio or video to connect to.

## What's in it

| Conversation | Shows |
| --- | --- |
| 🚀 **Spring launch** · favourite | The hero shot. A pinned message, a **thread** with replies, an image with a caption, a reply, reactions from several people, an **edited** message, a link preview, a poll, an @mention, a PDF, and a **scheduled message** waiting to go out |
| **Sofia Marín** | A **voice message**, 2 unread, and a **reminder** you set |
| ☕️ **Watercooler** · all 12 people | A busy group: photos, lots of reactions, 9 unread, which is enough for kvidr's **summary** offer |
| 🎨 **Design crit** | A **call in progress**, 4 unread including an @mention of you, and two images |
| 📣 **Announcements** · read-only | An `@all` message, a pinned message, and a composer you can't type in |
| **Jonas Berg** | A finished 23-minute **call** in the transcript; Jonas is away with a status message |
| 🛠️ **Engineering** · favourite | A Swift code block, a quote, a reminder, and another scheduled message |
| **Theo Lindqvist** | Theo is **out of office**, so kvidr shows the absence bar and suggests asking Jonas instead |
| 🍜 **Friday lunch** | A shared **location** and a food photo |
| **Amara Okafor** | A moodboard from last week |
| **Note to self** | A checklist and some inline code |
| 🧪 **Beta feedback** | An **open** conversation, joinable with a link |
| 📚 **Book club** | **Archived** |

Everyone has a photo and most people have a status, so the participant list in the
inspector looks lived-in too. The whole story is in [`scenario.json`](scenario.json). Edit
it and seed again to change it.

## Photos

The portraits and photos are listed in [`media.json`](media.json). They come from
[Unsplash](https://unsplash.com/license) and [Pexels](https://www.pexels.com/license/),
whose licences allow commercial use such as the App Store and a website, with no
attribution required. The one thing neither allows is implying that the people pictured
endorse the product, so don't quote them or name them as customers.

`seed.py` downloads anything missing into `media/`, which git ignores. To use a different
photo, replace the file in `media/` (avatars must be square) or change its URL in
`media.json`. A photo that can't be downloaded gets a generated placeholder, so the layout
still works.

## Starting over

```sh
./setup.sh --reset            # delete the server entirely, then start and seed a fresh one
./setup.sh -- --wipe          # keep the server; delete the conversations and seed again
python3 seed.py --keep-call   # only restart the call (it ends when nobody checks in)
docker compose down -v        # remove everything when you're done
```

The dates are relative to when you seed, so seed again on the day you take the
screenshots. After a reset, sign out of the account in kvidr (or remove it). The app's
cache still holds the old conversations, and the server's new conversation IDs won't
match them.

## Mac-only details

- **The voice message is real speech.** On a Mac, `seed.py` records it with the built-in
  `say` and `afconvert`, so kvidr's transcription has words to find. On any other machine
  it gets a synthetic murmur that only looks like speech in the waveform.
- **Scheduled messages really are scheduled.** They show in kvidr's scheduled list, and
  Nextcloud will send them when their day comes, if the server is still running then.

## `scenario.json`

```jsonc
{
  "password": "…",               // everyone's password
  "me": "freja",                 // the account you sign in as
  "users": {
    "sofia": { "name": "Sofia Marín", "status": "online",   // online | away | dnd | offline
               "statusIcon": "🎨", "statusMessage": "Designing",
               "absence": { "from": "-2d", "until": "+6d", "status": "🏝️ On holiday",
                            "message": "…", "replacement": "jonas" } }
  },
  "conversations": [{
    "key": "launch",                        // any unique name
    "type": "group",                        // group | public | one-to-one (+ "with") | note-to-self
    "name": "Spring launch", "emoji": "🚀", "color": "0082c9", "description": "…",
    "owner": "freja",
    "members": ["sofia", "jonas"],          // or "everyone"
    "favorite": true, "archived": false,    // as seen by "me"
    "readOnly": false,
    "unread": 0,                            // how many of the last messages "me" hasn't read
    "liveCall": ["amara", "ines"],          // people in a call that's still going
    "scheduled": [{ "at": "+4d 09:00", "text": "…" }],   // sent later, by "me"
    "messages": [
      { "at": "yesterday 16:05", "from": "sofia", "text": "Markdown **works**", "pin": true },
      { "key": "q", "from": "jonas", "text": "A question?", "thread": "Thread title" },
      { "from": "sofia", "in_thread": "q", "text": "An answer, inside the thread" },
      { "from": "freja", "text": "A reply", "reply_to": "q", "edit": "A reply, edited",
        "reactions": { "👍": ["sofia", "jonas"] }, "remind": "+1d 09:00" },
      { "from": "amara", "file": "photo.jpg", "caption": "optional" },     // from media/
      { "from": "sofia", "voice": "What the voice message says." },
      { "from": "ines", "location": { "name": "…", "latitude": 55.68, "longitude": 12.58 } },
      { "from": "ines", "poll": { "question": "…", "options": ["A", "B"], "maxVotes": 1,
                                  "votes": { "freja": [0], "sofia": [1] } } },
      { "call": { "with": ["freja", "jonas"], "minutes": 23 } }            // a finished call
    ]
  }]
}
```

**Times.** `at` is in your Mac's time zone and can be:

- `-40m` or `-2h`: that long before now
- `today 09:14`, `yesterday 17:30` or `-3d 12:05`: a clock time on a given day
- `+5m`: after the previous message
- `tomorrow 09:00` or `+4d 09:00`: in the future, for reminders and scheduled messages

A message without `at` comes a minute after the one before it. Use relative times for
today's messages, because a clock time later than now puts a message in the future.
The script warns if that happens. Mention someone with `@userid` and everyone with `@all`.

## Other servers

`python3 seed.py --server https://cloud.example.com --admin you --admin-password … --no-backdate`
seeds any Nextcloud where you're an admin, using only the public APIs. Some things need
direct database access, so they only work with the server in `compose.yaml`: the
backdating, a realistic call duration, and tidying the "joined the call" messages.
Elsewhere, every message is timestamped when the script ran. The server also needs to be
one you're happy to add twelve made-up people to.
