# Screenshot data

A throwaway Nextcloud with Talk, filled with a believable week of conversations, for
screenshots on the website and in the App Store. Nothing here touches the app: kvidr signs
in to it like any other server.

## Quick start

Needs Docker Desktop and Python 3. The Python that comes with Xcode's command-line tools is
enough; the script uses only the standard library.

```sh
cd Tools/screenshot-data
./setup.sh
```

That starts Nextcloud on <http://localhost:8080>, installs Talk, creates seven people and
eight conversations, and then **backdates** every message. That way the sidebar says
"Yesterday" and "Tuesday", and the transcript has day separators, instead of everything
having been sent a few seconds ago.

Then in kvidr:

1. **Settings → Advanced → Allow insecure local servers** on. Plain HTTP is only ever
   allowed for localhost and private addresses.
2. Sign in to `http://localhost:8080`. The browser opens Nextcloud's login page: sign in
   as **`freja`** / **`kvidr-screenshots-2026`** and approve the app.

## What you get

| Conversation | Why it's there |
| --- | --- |
| 🚀 **Spring launch** (favourite) | The hero shot: replies, reactions, Markdown, a link, an image, a poll, a mention |
| **Sofia Marín** | One-to-one, 2 unread |
| 🎨 **Design crit** | 4 unread including an @mention of you, and an image |
| **Jonas Berg** | One-to-one; Jonas shows as away with a status message |
| 🛠️ **Engineering** (favourite) | A Swift code block |
| 🍜 **Friday lunch** | A few days old |
| **Amara Okafor** | A shared image from last week |
| 📚 **Book club** | Archived |

All of it lives in [`scenario.json`](scenario.json). Edit it and seed again to change the
story.

## Making it look good

- **Profile pictures.** Put a *square* JPEG or PNG at `media/avatars/<user id>.jpg`, for
  example `media/avatars/sofia.jpg`. Without one, people get Nextcloud's initials avatar.
- **Photos in messages.** A message with `"file": "app-icon-final.png"` uploads
  `media/app-icon-final.png` if it exists. If it doesn't, the script generates a gradient
  placeholder so the layout is still right.

Both folders are ignored by git, so stock photos and anything licensed stay on your Mac.
Make sure you're allowed to publish whatever you put there.

## Starting over

```sh
./setup.sh --reset            # delete the server entirely, then start and seed a fresh one
./setup.sh -- --wipe          # keep the server; delete the conversations and seed again
docker compose down -v        # remove everything when you're done
```

Sign out of the account in kvidr (or remove it) after a reset. The app's cache still holds
the old conversations, and Nextcloud's new tokens won't match them.

## `scenario.json`

```jsonc
{
  "password": "…",             // everyone's password
  "me": "freja",               // the account you sign in as
  "users": {
    "sofia": { "name": "Sofia Marín", "status": "online",   // online | away | dnd | offline
               "statusIcon": "🎨", "statusMessage": "Designing" }
  },
  "conversations": [{
    "key": "launch",                        // any unique name
    "type": "group",                        // or "one-to-one", with "with": "<user id>"
    "name": "Spring launch", "emoji": "🚀", "color": "0082c9",
    "description": "…",
    "owner": "freja", "members": ["sofia", "jonas"],
    "favorite": true, "archived": false,    // as seen by "me"
    "unread": 0,                            // how many of the last messages "me" hasn't read
    "messages": [
      { "at": "yesterday 16:05", "from": "sofia", "text": "Markdown **works**" },
      { "key": "q", "from": "jonas", "text": "A question?" },
      { "from": "freja", "text": "An answer", "reply_to": "q",
        "reactions": { "👍": ["sofia", "jonas"] } },
      { "from": "amara", "file": "photo.jpg", "caption": "optional" },
      { "from": "ines", "poll": { "question": "…", "options": ["A", "B"], "maxVotes": 1,
                                  "votes": { "freja": [0], "sofia": [1] } } }
    ]
  }]
}
```

**Times.** `at` is in your Mac's time zone and can be:

- `-40m` or `-2h`: that long before now
- `today 09:14`, `yesterday 17:30` or `-3d 12:05`: a clock time on a given day
- `+5m`: after the previous message

A message without `at` comes a minute after the one before it. Use relative times for
today's messages, because a clock time later than now puts a message in the future.
The script warns if that happens.

Mention someone with `@userid` in the text.

## Other servers

`python3 seed.py --server https://cloud.example.com --admin you --admin-password … --no-backdate`
seeds any Nextcloud where you're an admin, since it only uses the public APIs. Backdating
needs direct database access, so it only works with the server in `compose.yaml`. Elsewhere,
every message is timestamped when the script ran. The server also needs to be one you're
happy to add seven made-up users to.
