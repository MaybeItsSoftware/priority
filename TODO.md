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
  and the cursor row should simply be unmistakable.
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

## Code

### Window restore does not clamp to a visible screen

`MainWindowController` restores a saved frame without checking it against
`NSScreen.visibleFrame`, so unplugging a monitor can strand the window
off-screen with no way back but deleting the preference. Small fix.

### Most surfaces still ignore the theme

The theme plugin is real and switchable, but only four shared primitives
(`MicroLabel`, `KeyCap`, `KeyHint`, `FocusRule`) and the sidebar's selection
background render through it. The board, the outline pane, the inspector,
Today, the timeline and all of Settings bar the theme page still use
`Color.accentColor` and literal radii.

Two mechanisms are therefore live at once — the plugin, and the older
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
