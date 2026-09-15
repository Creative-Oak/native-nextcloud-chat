# Command palette — design

*15 September 2026. Replaces the ⌘K quick switcher.*

A Spotlight-style palette, opened with ⌘P (and ⌘K), that finds conversations, people
and messages and runs every command the app has.

## 1. Look and presentation

Two separate pieces of Liquid Glass with a gap between them, as Spotlight floats over the
desktop.

- **The field**: a 52pt glass capsule (`.glass(.field)` — the message field's glass, so
  the text cursor does not fight a hover highlight), a magnifier, 20pt text, prompt
  "Search Kvidr". Centred, its top about a fifth of the way down the window. The window
  behind dims slightly; a click there dismisses.
- **The results**: a second glass panel (`.glass(.panel)`, 14pt corners) beneath, 640pt
  wide, growing with content to ~60% of the window's height, the switcher's soft shadow.
  Rows are 44pt: a 26pt face or symbol, a title, a secondary line (last message, snippet,
  or the command's shortcut), a kind label at the trailing edge. The highlighted row has
  a rounded accent fill inset 6pt from the panel's edge. Section headers are small grey
  caps: Top Hit, Conversations, Commands, People, Messages.
- **Empty query**: the first eight conversations in sidebar order and, under Commands,
  six fixed ones — New Conversation, Search Messages, Use Compact/Full Sidebar, Refresh,
  Show Conversation Details, Keyboard Shortcuts.
- **Nothing found**: one quiet row, "No results for '…'"; the panel never vanishes while
  there is text.

Scale-and-fade in from the capsule, and out the same way. Escape, ⌘P again, or a click
outside dismisses.

## 2. Gathering and ranking

One `@Observable` `CommandPaletteModel` owns the query and produces sections from four
sources:

- **Conversations** — local, instant. The index filtered with `localizedStandardContains`
  on the display name; ranked exact prefix, then word prefix, then substring; ties keep
  the sidebar's order. Capped at 5.
- **Commands** — local, instant. Matched on title and aliases, same ranking, capped at 5.
  A disabled command is listed greyed and unselectable, with the reason as its secondary
  line ("Select a conversation first").
- **People** — the directory (`ParticipantService.search`): users, groups, teams.
  Debounced 250ms, cancelled by the next keystroke. Anyone with an existing 1:1 appears
  instantly from the index and is de-duplicated when the server answers. Capped at 4.
- **Messages** — `MessageSearchService.searchMessages(term:)` across all conversations,
  same debounce and cancellation. Capped at 5, then a "See all results for '…'" row.

**Top Hit** is the best-scoring row across the *local* sources only, so it never changes
under the pointer. Sections render in a fixed order; server sections append when they
arrive and never reorder what is above. An in-flight server call shows a thin progress
line in its section, not a row.

Errors: a failed or offline server search leaves its section out; local sections still
work; "See all results" still opens the sheet, which reports its own errors. Queries
under two characters skip the server.

Ranking is a pure function over plain values, covered by `swift test`.

## 3. Commands — one registry

- **`AppCommand`**: `id`, `title`, `aliases`, `shortcut`, `menu`, `isEnabled: () -> Bool`,
  `perform: () -> Void`.
- **`AppCommandRegistry`**: built by `RootView`, which has the `AppModel`, `Preferences`
  and the focus requests. Replaces the separate focused values with one, `\.appCommands`.
- **`TalkCommands`** renders the registry, grouped into the same menus in the same order.
  State-dependent titles ("Use Full Sidebar", "Remove from Favourites") stay computed.
- **The palette** lists the registry minus itself. Choosing a command runs `perform` and
  closes.

Added: **Go to Anything**, ⌘P, with a second entry carrying ⌘K. Follow-up, not part of
this: the Keyboard Shortcuts window lists the registry instead of a hand-kept table.

## 4. Keys and actions

- **Open**: ⌘P, ⌘K, or the menu. Focus is remembered and restored on dismiss. ⌘P while
  open selects the text.
- **Move**: ↑/↓ across every selectable row, skipping headers and disabled commands;
  ⌘↑/⌘↓ jump sections. The list scrolls to keep the highlight visible.
- **Choose**: Return, or a click. Return on a conversation, person or message opens it
  *and* puts the cursor in the message field — "⌘P, type, Return, type" is the whole flow.
- **Escape**: clears the text if there is any; a second Escape closes.

By kind:
- **Conversation** → `selectedToken`, then the composer. The sidebar's width is left alone.
- **Message** → its conversation, scrolled to the message with the highlight flash
  (`highlightRequest`), then the composer. A hit with a `threadID` is labelled
  "Message · in thread" and opens the same way; there is no thread view yet.
- **Person** → the existing 1:1 if the index has one, else
  `ConversationService.create(.oneToOne(with:))`, then as a conversation. Creation shows
  the progress line and reports failure in place ("Couldn't start a conversation").
  Groups and teams go through the existing `NewConversation` request types.
- **Command** → `perform()`, close.
- **See all results** → close, open the Search Messages sheet with the term and
  "All Conversations".

## 5. Pieces and testing

New, under `Kvidr/Features/Palette/`:
- `CommandPaletteView` — capsule, panel, sections, rows, keys. Replaces `QuickSwitcher`.
- `CommandPaletteModel` — query, sections, the two debounced server tasks, creation state.
- `PaletteRanking` — pure scoring, ordering, capping, top hit. Where the tests are.

New, under `Kvidr/App/`: `AppCommand`, `AppCommandRegistry`.

Touched: `RootView`, `TalkCommands`, `MessageSearchSheet` (initial term and scope),
`KeyboardShortcutsWindow` (⌘P).

Tests: prefix beats word-prefix beats substring; ties keep order; diacritic-insensitive;
caps; top hit only from local sources; registry ids unique, every command titled, ⌘P and
⌘K both open the palette.

Verified by hand: the Spotlight likeness, the debounce feel, creating a DM against a real
server.
