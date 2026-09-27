# Zed overhaul plan

The aim is for Priority to feel the way Zed feels: a utilitarian layout, an
interface you can work out without memorising it, and every keystroke answered
within a frame. It stays what it is — a Blitzit-style task app with focus
sessions and time tracking, and a right-hand rail of what you actually finished.
Theming stays customisable: every change below goes through theme tokens
(`ThemeStructure` spacing/radius/type, `ThemePalette` roles), never literals.

This plan comes from an audit of layout, responsiveness and keyboard UX, done
on 2026-09-27. Phases are ordered so each one lands green on its own.

## Phase 1 — keyboard correctness

- `DesktopShortcutSequence` swallows any key that could begin a two-letter
  command (`x`, `l`, `h`, …) and never replays it. A held key must run its own
  single-key binding when the next key doesn't complete a sequence, or when
  the prefix times out.
- The focus screen has to own the keyboard, not just claim to. Keys its
  handlers ignore currently fall through to the hidden task surface.
- Every key is dispatched through `WorkspaceCommandCatalog` by surface, not
  through a hand-written switch plus a second copy of the sequence list. That
  makes a dead advertised key (`⌘⌃C`, the ladder's `o`) impossible, and a test
  asserts every catalogue key resolves to a handler.

## Phase 2 — the data path

- A mutation reloads only what it changed. There is no full-workspace fan-out
  (nested lists twice, the board, next-up) per keystroke, and the cost scales
  with what is on screen.
- `perform` does its side effects once per user action (draft refresh,
  `onLocalWrite`). Read-only refreshes don't schedule a sync.
- There are no SQLite reads during view body evaluation. `task(withID:)`
  serves from a cache that covers every surface on screen.
- Selection changes invalidate two rows, not the whole window or every board
  card. Rows are their own `View` structs, fed values.
- External-write polling does a targeted reload, and its read never blocks
  behind a writer.
- Launch shows the window before non-essential work runs. Legacy migrations
  and the Checkvist import run after first paint.

## Phase 3 — overlays instead of sheets, and a Zed-shaped shell

- One overlay host: top-anchored, instant, and without a title bar. The command
  palette, search, list navigator (the "file finder"), move picker, quick edit
  and keyboard reference all render there. Overlays can replace each other
  (⌘K from search opens the palette). Escape closes and Return confirms,
  everywhere. The window's key monitor stays live, and the overlay owns the
  keys it consumes.
- **Left dock**: the sidebar, toggleable and persisted, as now.
- **Right dock**: the inspector and the done rail as tabs of one resizable
  dock, persisted (visibility, width, active tab). It no longer closes itself
  on navigation. With no selection the inspector says so rather than
  vanishing.
- **Status bar**: a thin bottom strip. The left holds dock toggles and the
  keyboard-focus region; the middle shows a pending key-sequence prefix and
  transient messages; the right holds the running focus session, today's
  points or planned time, and sync state.
- **Title bar**: a slim title bar with the mode strip only. The Focus,
  Timeline and Done toggles move to the status bar, so each control has
  exactly one home.
- Focus and Timeline stay full-pane screens: they are the Blitzit heart of the
  app. They are reached from the mode strip, the palette and the keyboard, and
  are not duplicated as sidebar rows.

## Phase 4 — the visual pass

- One flat surface for panes. Docks are separated by hairlines rather than
  tints, and there are no rounded, filled cards-on-wells, gradients or capsule
  pills. Board cards are bordered rows.
- Every padding and font size comes from theme tokens. The ad-hoc 14/18/20/24/
  26/28 paddings and 9–30pt literal font sizes go. The only exceptions are the
  focus timer and the other hero numerals, which get named display tokens.
- The surfaces that still ignore the theme (move, quick edit, the quality
  prompt, DayView, Settings) are brought onto it.

## Phase 5 — keymap, menus and docs

- A user keymap at `~/Library/Application Support/Priority/keymap.json`,
  overlaying the catalogue's defaults per surface. Invalid entries are
  reported, not fatal. A palette command opens the keymap file. The unused
  remapping stack (`ConfigurableShortcutAction`, `ShortcutResolver`,
  `ShortcutGate`, `ShortcutSequenceBuffer`) is either reused for this or
  deleted.
- There is a Task menu, so every task action is reachable and its key is
  visible without the palette. Two-letter sequences get chord alternatives
  where one is free.
- Return and Shift-Return mean the same thing on every task surface.
- README, `docs/keyboard-shortcuts.md` and the roadmap are corrected to match,
  including the onboarding boxes that never display and the palette rows that
  don't exist.

## Out of scope

Tabs and split panes. Priority shows one scope at a time, and the docks cover
the need for a second surface.
