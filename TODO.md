# TODO

Outstanding work and open decisions. Ordered by who can act on it: decisions
only Adam can make, then checks that need a pair of hands, then code.

Things get deleted from here when they are done, not ticked — `git log` is the
record of what happened.

## Decisions owed

### What `→` should do within Today

Currently unbound. The candidate is "open the selected task in its list",
mirroring `→` in the outline meaning "go in" — but that switches view mode,
which is a lot for an arrow key, and it makes `←` not a true inverse.

**Recommendation: leave it unbound.**

### The typed-command language

`Sources/PriorityCore/CommandEngine.swift` parses `due tomorrow 9am`, `tag x`,
`matrix do` and much more — about 1,400 tested lines with exactly one caller,
`AppCoordinator.executeCommandInput`, which nothing calls. It was deliberately
left out of the `Cmd+K` palette: it is a different interaction (arguments,
natural-language dates) and bolting a text grammar onto a row list would make
both worse. `README.md` marks it as currently unreachable.

Either give it a `:` prefix inside the palette that switches to text-command
mode, or delete it.

**Recommendation: the `:` prefix.** The parser is good and the due-date
language is genuinely faster than a picker.

### The theme branch worktree

`.claude/worktrees/agent-abbc9291be63498f4` still exists, holding branch
`worktree-agent-abbc9291be63498f4`. Four of its five commits are on `main`; the
fifth was a migration of `EisenhowerMatrixView` and `PopoverView+Dock`, both of
which were deleted from `main` before the branch landed, so it was dropped
rather than merged. Nothing is lost by removing the worktree and the branch.

It also means `swiftlint lint` run from the repository root reports the
worktree's copies of everything, roughly doubling the count. Filter with
`grep -v '\.claude/worktrees'` until it is gone.

## Checks that need a pair of hands

These cannot be verified from a build; they need someone to click.

- **The done rail.** `⌘⌃D`. It should open on the right of the inspector with the
  keyboard already in it, `↑↓`/`kj` should walk the list across day headings as
  one sequence, `⏎` should land on the task in its own list with completions no
  longer hidden, `R` should put it back on the list, and `←` should hand the
  keyboard back to the work. Pressing `⌘⌃D` again from inside it closes it;
  pressing it while the keyboard is elsewhere should bring the keyboard over
  rather than close the rail.
- **The rail's window is five weeks** (`WorkspaceViewModel.doneRailWindowDays`).
  Say if that is the wrong depth — too short to see a pattern, or long enough to
  feel like an archive.
- **Cancelled tasks appear in the rail**, drawn apart from completed ones. Say if
  they should not be there at all: they leave the open list the same way, which
  is the argument for listing them, but they are not progress.
- **The flattened sidebar.** It is `theme.altRow` rather than `.bar` now, so it
  no longer picks up what is behind the window. Check the selection wash reads,
  and that the sidebar still separates from the pane beside it.
- **Timeline then a list.** Click Timeline, then click any list. The list should
  open. This was silently broken.

- **The focus handoff.** Start a block from a board card. The window should
  close, the Dock icon should go, and the tray should come up with the running
  task at the top. Score the block on the tray: the window should stay closed.
  `Window → Priority` should reopen on the focus screen, not the plan.
- **A daily starting itself** should leave the window alone — only deliberate
  starts close it.
- **Menu-bar block controls.** Click the status item mid-block. Expect the task
  title, a clock row, Pause/Resume, Done and End Block. **Done** should raise
  the tray and ask how the block went, not silently close it.
- **The sidebar's two cues.** Arrow onto Focus: the list you were reading should
  stay open behind it, the ring should read as "you are here" and the fill as
  "this is open". If that distinction is too fine to carry, the fill should go
  and the cursor row should simply be unmistakable. These now carry the whole
  job: the current row no longer thickens its name, so if it reads too quietly
  the resting fill is one figure (`WorkspaceSelection.restingFill`, 0.13).
- **`⌘↑` / `⌘↓` on a nested list.** That path did nothing at all before, so it
  is the least-exercised thing in the sidebar work.
- **Folder scope.** Is the board the right mode to land in, or should it keep
  whichever mode you were already in? And the new-task picker inside a folder
  should offer only that folder's lists.
- **The chrome migration.** Key caps, the hint bars under the focus screens and
  the sidebar ring all changed rendering path, even on Chalk. Nothing should
  look different; check that nothing does.
- **The outline's last `←`.** With no task selected and Everything already
  showing, `←` drops into the sidebar. That may be one press too many.
- **The one selection treatment, on every surface.** A selected row now carries
  a ring when its region has the keyboard and only a fill when it does not. Six
  surfaces changed to get there — the outline, Today, the board, search, the
  palette, the move sheet — and the figures came from the sidebar, where they
  were tuned as a pair. Worth arrowing between the sidebar and the task surface
  to check the ring reads as "this responds to me" rather than as noise.
- **The menu keys, all of them.** Nineteen literal `keyboardShortcut` calls
  became catalogue lookups, so a wrong lookup is a menu item with the wrong key
  or none. Open every menu and check what it prints beside each item.
- **⌘⌃S and the inspector toggle.** Both were menu-only and are now catalogue
  entries, so they also answer from the window monitor and appear in the
  palette. Check they do not fire while you are typing in a field.
- **The three new keys.** `⌘⌃C` removes the column the selected card is in,
  `o` on the focus ladder drops your own order, and both now print their key in
  their tooltip. `⌘⌃C` is deliberately not `⇧⌘⌫`, which still deletes the list.
- **The one header band, in all five modes.** `⌘1`→`⌘2`→`⌘3`→`⌘4`→`⌘8`→`⌘9`
  in sequence: nothing should move but the content. The title size is 17pt for
  all of them, which is smaller than the 20 and 22 it replaces — if the scope
  name now reads too quiet, it is one figure (`WorkspacePaneHeader.titleSize`).
- **The inspector's new order.** Title, then Start focus, then Notes, Plan,
  When, Filing, Links, Structure, Save. Worth checking the order matches how
  you actually work through a task, because it was guessed from what the
  controls are rather than from watching anyone use them.
- **The board column's two rings.** Drag a card over a column, then arrow into
  one. The drop target is the primary hue at 2pt; the keyboard is the focus ring
  at a hairline. They used to be the same 2pt accent ring.
- **Did anything want the fifth view mode?** `WorkspaceViewMode.focus` and its
  dashboard are gone. Nothing reached them, but if a muscle-memory key lands on
  a pane that is now missing, that is where it went.

### One on-screen control still has no key

The subtask disclosure on a board card is `@State` local to the card, so no
command can reach it — the model does not know which cards are open. Giving it
a key means moving that state onto the workspace, keyed by task id, which is
worth doing but is not a tooltip change.

## Code

### Window restore does not clamp to a visible screen

`MainWindowController` restores a saved frame without checking it against
`NSScreen.visibleFrame`, so unplugging a monitor can strand the window
off-screen with no way back but deleting the preference. Small fix.

### Surfaces that still ignore the theme

What renders through it now: the shared primitives (`MicroLabel`, `KeyCap`,
`KeyHint`, `FocusRule`, `WorkspacePaneHeader`, `SheetTitle`,
`InspectorSection`), the toolbar, the board card and column, the one selection
treatment everywhere it is drawn, the timeline including its per-task hues, the
focus screens, the matrix, the inspector, the sidebar and the task composer.

What does not: the move sheet, the quick-edit sheet, the sidebar drop targets,
the focus quality prompt, most of the day tray (`DayView`), and all of Settings
bar the theme page. Around 20 `Color.accentColor` uses remain, concentrated in
`DayView` and `WorkspaceTaskQuickEditSheet`.

### Two theme mechanisms are still live

A useful count while migrating: `grep -c accentColor Priority/*.swift`.

Two mechanisms are live at once — the plugin, and the older
`AppThemeColorToken` / `PreferencesManager.themeColor(for:)` with its per-token
overrides and theme JSON import/export. A surface counts as migrated when its
local `themeColor(_:)` helper is gone. See `docs/plugins.md`.

### The theme asks for fonts that are not bundled

Chalk requests `Arvo` (slab serif, brand and body) and `Geist Mono`, falling
back to the system serif and `SF Mono` when they are absent — which they are,
so the slab serif that is much of the house character is not currently on
screen. To ship them: add the `.ttf`s as a resource, list them under
`ATSApplicationFontsPath` in the Info.plist, and check the licences. Nothing in
the theme contract changes.

### Theme values that were guessed

Worth an eye from someone who owns the palette:

- **Dark `altRow`, `borderMuted` and `inputBorder`** have no stated hex in the
  house style. They were derived from the grape ramp as `#211f29`, `#2d2b38`
  and `#403d4d`. These now carry more weight than they did, because Chalk Dark
  is a theme someone may sit in all day rather than only what Chalk becomes
  after sunset.
- **How status accents are scored.** Emerald is 2.08:1 on chalk and amber
  1.56:1, so holding every accent to 4.5:1 would condemn the house palette.
  The audit instead holds only `primary` to 3:1 — it carries focus rings and
  selection edges — and records any accent under 4.5:1 as a *note* saying it is
  unsafe for body copy. Success, danger and warning are always a tinted fill
  plus border plus text of the same hue, never a bare mark on paper, so this is
  defensible; the stricter alternative is to composite the tint over the paper
  and measure against that, which is more work and would still fail for amber.

### Known-good backlog, not yet claimed

- `WorkspaceViewModel.swift` is past SwiftLint's `type_body_length` warning.
  The standing count is 35 violations, 0 errors; do not add to it.
  `ARCHITECTURE_IMPROVEMENT_PLAN.md` tracks the decomposition.
