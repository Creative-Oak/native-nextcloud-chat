# kvidr for Raycast

Four Raycast Script Commands that drive kvidr through its `kvidr://` links:

| Command | What it does |
|---|---|
| **Open Conversation** | Opens a conversation by name — "Anna", "Budget". |
| **Write Message** | Opens the conversation with your words already in the field. Return sends. |
| **Catch Up** | kvidr's Apple Intelligence summary of every unread conversation. |
| **Find Conversation** | Filters kvidr's sidebar. |

## Setting up

1. In Raycast: **Settings → Extensions → Script Commands → Add Directories**, and pick this
   folder (`Integrations/Raycast`).
2. The commands show up under **kvidr**. Give them aliases or hotkeys as you like.

## Why links never send

A `kvidr://` link can come from anywhere — a web page included — so a link only ever opens
kvidr or fills in the field. **Write Message** leaves the message in the field for you to send.
To send without looking, use kvidr's **Send Message** action in Shortcuts (or Siri), which
Raycast can run too: **Search Shortcuts** in Raycast lists them once you've made one.

## The links

```
kvidr://open?conversation=<name or token>
kvidr://compose?conversation=<name or token>&text=<words>
kvidr://catch-up
kvidr://search?q=<words>
```
