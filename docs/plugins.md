# Plugin Development Guide

Priority ships with native plugins only. Plugins are self-contained and live under:

- `Priority/Plugins/Native/Checkvist/`
- `Priority/Plugins/Native/Obsidian/`
- `Priority/Plugins/Native/AFFiNE/`
- `Priority/Plugins/Native/GoogleCalendar/`
- `Priority/Plugins/Native/MCP/`
- `Priority/Plugins/Native/DailyLog/`
- `Priority/Plugins/Native/Celebration/`
- `Priority/Plugins/Native/Theme/`

`SettingsView` renders plugin settings from active native plugins through shared protocols.

## Core Interfaces

Plugin contracts are defined under `Priority/Plugins/Protocols/`:

- `Plugin` — the base identity contract every plugin conforms to
- `CheckvistSyncPlugin`
- `ObsidianIntegrationPlugin`
- `AFFiNEIntegrationPlugin`
- `GoogleCalendarIntegrationPlugin`
- `MCPIntegrationPlugin`
- `DailyLogPlugin` (in its own file, `Protocols/DailyLogPluginProtocol.swift` — see below)
- `CompletionCelebrationPlugin` (likewise, in
  `Protocols/CompletionCelebrationPluginProtocol.swift` — see below)
- `ThemePlugin` (likewise, in `Protocols/ThemePluginProtocol.swift` — see below)
- `PluginSettingsPageProviding`

Plugin registration lives in `Priority/Plugins/Registry/PluginRegistry.swift`.

## Native Plugin Rules

- Keep each plugin self-contained in its own folder (logic + settings UI extension).
- Do not place plugin-specific services/models in app root.
- If a plugin has settings, define them in a plugin-local `+Settings.swift` file.
- `SettingsView` should stay generic and never add plugin-specific switch/case logic.

## Responsibilities By Capability

### Checkvist (`CheckvistSyncPlugin`)

- Authentication/token lifecycle (`login`, `clearAuthentication`).
- Task/list fetch and task mutation operations.
- Cache persistence and stale-cache checks.

### Obsidian (`ObsidianIntegrationPlugin`)

- Inbox/linked-folder selection and clearing.
- Markdown export/open behavior via `syncTask(...)`.

### AFFiNE (`AFFiNEIntegrationPlugin`)

- Locating the user-installed `affine-mcp` helper, and reporting where it looked.
- Workspace discovery and selection.
- The two-way checklist: writing a list's open tasks as todo blocks under
  `## Tasks`, and reading back the boxes ticked in AFFiNE.
- Writing a day's `## Log` block, from `DailyNoteMarkdown`'s rendering.
- Remembering which document each list's checklist lives in.

Closing a ticked task is *not* the plugin's job — `syncChecklist` hands the
ticked ids to a `closingTicked` callback and `IntegrationCoordinator+AFFiNE`
applies them through the mutation service, then feeds the refreshed list back
so the write reflects the closes.

The plugin is an MCP *client*: AFFiNE documents are Yjs block trees rather than
text, so the writing is done by `affine-mcp-server` over stdio and Priority never
handles an AFFiNE credential. See `docs/affine.md`.

### Google Calendar (`GoogleCalendarIntegrationPlugin`)

- Event URL composition for selected tasks.
- Due-date mapping decisions for event timing.

### Google Tasks (`GoogleTasksIntegrationPlugin`)

Transport for the Google Tasks mirror: lists, tasks, create, patch, delete and
paging. It decides nothing — what the mirror *should* do is `GoogleTasksMirror`
in `PriorityCore`, and when it should happen is `GoogleTasksMirrorService`.

One Google Tasks list per Priority list, with Priority as the source of
authority: local edits win and are logged when they overwrite something, while
completions, added notes and tasks created on the Google side are kept. See
`docs/google-tasks.md` for the full table and the reasoning.

### The shared Google account (`GoogleAccount`)

Calendar and Tasks are two APIs on one Google user, so the OAuth dance —
client ID, PKCE, the loopback receiver, the keychain item and refresh — lives
in `Priority/Plugins/Native/Google/` and both plugins are handed the same
`GoogleAccount`. Each declares the scopes it needs with `requireScopes` at
construction; signing in asks for the union of them.

Two consequences worth knowing:

- Scopes accumulate, and an existing sign-in does not grow on its own.
  Switching on an integration that was added later leaves a token whose grant
  predates it, so `hasGrantedScopes` is false and the settings page says to
  sign in again. That is a real state, not an error to swallow.
- A 401 invalidates the shared sign-in, because the token Google rejected is
  the one every Google integration is using.

The first token was stored under a Calendar-specific keychain account, and the
client ID under a Calendar-specific defaults key. Both are adopted on first
read rather than abandoned, so an existing Calendar sign-in survives the move.

Google Tasks needs the Tasks API switched on in the same Google Cloud project
as the OAuth client. Sign-in succeeds without it and every call then fails with
a 403, which is worth knowing before debugging the mirror.

### MCP (`MCPIntegrationPlugin`)

- Resolve server command and optional guide path.
- Generate MCP client configuration JSON.

### Daily Log (`DailyLogPlugin`)

- Append-only event log (completions, reopens, invalidations, finished focus
  sessions, the day's plan snapshot) under
  `~/Library/Application Support/Priority/daylog.jsonl`.
- Logical-day keying against a configurable rollover hour.
- Projections for the Daily view and the note writer, so both render a day the
  same way.
- Managed-block writes into an Obsidian daily note.
- The set of **dailies** (recurring intentions) in `dailies.json` alongside the
  log.

The two files have deliberately different shapes. `daylog.jsonl` is history:
append-only, never rewritten, tolerant of a torn tail. `dailies.json` is
configuration: small, whole-file, atomically replaced. Renaming a daily should
change its name, not append a rename event that every reader has to replay.

Whether a daily is *done* is never stored on the daily — it is a question about
a specific day, answered from the log by
`DayLogAggregator.completedDailyIds`. Anything that would need clearing at
rollover eventually doesn't get cleared.

Daily ticks net **within a logical day only**, unlike task completions, which
net across the whole log. That is the entire behavioural difference between a
habit and a task: reopening a task reaches back to whichever day completed it,
whereas un-ticking a daily today must not blank yesterday's square.

This plugin breaks two conventions on purpose, both for the same reason:

- Its contract lives in `Protocols/DailyLogPluginProtocol.swift` rather than in
  `PluginProtocols.swift`, and
- the whole `Native/DailyLog/` folder is excluded from the `PriorityPlugins`
  SPM target.

Both follow from the module boundary: the plugin traffics in `PriorityCore`
types (`DayLogEvent`, `DayBoundary`, `DayLogAggregator`), a file can only belong
to one SPM target, and the Xcode app compiles everything as one module where
`import PriorityCore` isn't available. `MCPClientInstaller.swift` is app-only
for exactly the same reason. No coverage is lost — the logic worth testing lives
in `Sources/PriorityCore/` and is exercised by `corelogic-tests`.

Recording reaches the plugin through `TaskMutationHost.recordDayLogTaskAction`
(primitives only, since `PriorityAppLogic` can't see the event type either) and
through `FocusSessionManager.onFocusSessionCompleted`.

### Completion Celebration (`CompletionCelebrationPlugin`)

What completing a task or ticking a daily *looks like*. Four presets ship —
None, Strike (the default), Fold, Spark — and the user picks one in
Settings → Theme.

This capability is shaped differently from the others in three ways, all
deliberate:

- **It is a menu, not an integration.** Every preset registers; the user's
  choice is applied afterwards by `CompletionCelebrationManager`. It is the only
  capability with a list-them-all accessor (`PluginRegistry.celebrationPlugins`)
  and the only one whose registry reference is retained past `AppCoordinator.init`,
  because the active plugin can change at runtime.
- **Its settings live in the theme pane, not in a plugin card.** Registering
  four presets as `PluginSettingsPageProviding` would put four entries in the
  plugin sidebar for what is one setting.
- **It excludes itself from `PriorityPlugins`** — the whole `Native/Celebration/`
  folder plus its contract — for a variant of the `DailyLog` reason: celebrations
  are motion, motion is SwiftUI, and the SPM target can't have it. Everything
  worth testing therefore has to live in `Sources/PriorityCore/`, which is why a
  preset expresses its *timing* as a `CelebrationScript` rather than as a
  sequence of `Task.sleep` calls: `CompletionMilestonePolicy`,
  `CelebrationRowTreatment` and `CelebrationScript` are all covered by
  `corelogic-tests`, and the SwiftUI half is reduced to playing a schedule
  somebody else checked.

What a new preset actually implements:

- **`rowTreatment`** — what the row looks like at each `CelebrationPhase`, as
  data. Read it through the `for phase:` accessors; every surface applies it via
  the shared `.celebrating(_:)` modifier in `CelebrationRowView.swift`, so a
  preset never draws a row itself and a new surface gets the whole treatment for
  one line.
- **`inlineScript(for:reduceMotion:)`** — the blocking half's timing. Build it
  with `CelebrationScript.fitting`, which applies the reduced-motion scale and
  the budget *to the total* rather than to each step. A preset can still override
  `runInline` for something a schedule can't express, but
  `CompletionCelebrationManager` stops waiting on it at
  `inlineBudget` + a small grace either way, so a slow preset costs the app its
  animation rather than the user their task.
- **`celebrationSound(for:)`** — optional, off unless the user turns sound on in
  Settings → Theme. It exists because `NSHapticFeedbackManager` reaches only a
  Force Touch trackpad, and only while a finger is on it, so for most
  completions of a keyboard-first app the "tactile" confirmation reaches nobody.
- **`makeFlourish(_:)` / `makeRowAccent(for:)`** — optional decoration. The
  flourish runs *after* the mutation is dispatched and so may be showier; scale
  it by `CompletionMilestone.flourishWeight` rather than drawing every occasion
  identically.

Two constraints a new preset must respect:

- **Haptics are not yours.** They fire outside the protocol, for every
  completion, including under the "None" preset — they are confirmation that the
  keypress registered, not celebration, and turning the animation off shouldn't
  cost you them.
- **`runInline` blocks the close.** `TaskMutationService.markCurrentTaskDone`
  awaits it *before* sending the request and abandons the close if it returns
  `false`. That cancellation is real, not decorative: `NavigationState`
  reports movement to `CompletionCelebrationManager.cancelInFlight()`, so a user
  who fires a completion and immediately arrows away calls it off. Let
  `CancellationError` out of your sleeps — the default `runInline` does.

`CompletionMilestonePolicy` decides the *occasion* — ordinary, list cleared,
daily ticked, a run of consecutive days, or every tenth completion of the day.
Presets choose how to render an occasion, never which occasion it is.

### Theme (`ThemePlugin`)

What the app looks like: a colour palette and a structure set, under an
identity. Two themes ship — **Chalk**, the house style and the default, which
follows the system's Light/Dark setting, and **Chalk Dark**, the same palette
with the appearance fixed for running the app dark on a light desktop — and the
user picks one in the plugin's settings page.

Chalk Dark shares Chalk's `palette` and `structure` objects outright rather
than restating their hexes, so the two cannot drift; what makes it a theme of
its own is an identity and a `lockedAppearance`. A theme that sets that field
*is* that appearance, and picking it by name is the request — which is why it
overrides the system setting where an ordinary theme does not.

Shaped like `CompletionCelebrationPlugin` rather than like an integration, for
the same reason: it is a menu. Every theme registers, `ThemeManager` applies
the user's pick afterwards, and the registry is retained past
`AppCoordinator.init` because the active plugin can change at runtime.

A plugin declares three things and nothing else:

- **`palette`** — two tables of literal hex (`light` and `dark`), read through
  the semantic roles in `ThemeColorRole`. Components only ever name a role, so
  a theme swap and an appearance flip are the same mechanism. Roles in
  `ThemeColorRole.themeInvariant` — the letterbox behind a photo, the scrim
  under chrome sitting on an image, the text on that scrim — answer from the
  light table whatever the appearance, because the content underneath isn't
  ours to theme.
- **`structure`** — radii, border weights, the spacing scale and the type
  treatment, including the **micro-label** — in the built-ins caption-sized,
  regular, as written and muted, the way Zed labels a panel; its size, weight,
  tracking and case are all tokens. Use `.microLabel(theme)`; a hand-rolled
  `.font(.system(size: 12))` next to a muted colour is the same thing written
  out longhand, and a theme cannot reach it.
- **`preferredAppearance`** — advisory only. Light/dark/system stays the user's
  own setting; a theme does not get to answer it on their behalf.

`specification` composes the three with the `Plugin` identity and is defaulted,
so a native theme is a registration rather than a place to keep hex — the hex
lives in `Sources/PriorityCore/Theming/BuiltInThemeSpecifications.swift`, where
it is covered by `corelogic-tests`.

Like `DailyLog` and `Celebration`, this capability breaks two conventions for
the one reason: the contract sits in `Protocols/ThemePluginProtocol.swift` and
the whole `Native/Theme/` folder is excluded from the `PriorityPlugins` target,
because it traffics in `PriorityCore` types and one file can only belong to one
SPM target. Everything worth testing is therefore in `PriorityCore`:
`ThemeColorValue` (hex parsing, WCAG luminance and contrast), `ThemePalette`
(role resolution and the flip), and `ThemeSpecification.validate()`.

**User themes.** Themes can also come from JSON files in
`~/Library/Application Support/Priority/themes/` — the format is in
[`themes.md`](themes.md). They are not registered with `PluginRegistry`,
because they come and go while the app runs: `UserThemeLibrary` (in
`Native/Theme/`) watches the folder, decodes and merges each file through
`ThemeFileLoader` in `PriorityCore`, and vends a `UserThemePlugin` per file.
`ThemeManager` lists those after the built-ins and keeps the user's pick even
while its file is missing, rendering Chalk until it returns. Load problems go
to Diagnostics and the window's error line, the way `keymap.json`'s do.

**`validate()` is the guard rail.** A role missing from both tables is an
error; unreadable body text, an accent under 3:1 where it has to carry a focus
ring, a card you cannot tell from the page, a declared shadow, a gradient on
chrome, an off-scale radius or a hairline that is really a border are warnings.
An accent under 4.5:1 is a *note* — azure on chalk is 3.6:1, which is why it is
for headlines, large text, UI components and fills and never a paragraph of
body copy. The settings page prints the list.

**Rendering through it.** `ThemeManager` owns which theme is active;
`.themed(_:)` at each root — the window, the menu-bar popover, the settings
window — resolves it against the appearance SwiftUI reports and puts a `Theme`
in the environment. Views read `@Environment(\.theme)` and touch role names and
scale names only: `theme.paper`, `theme.panelRadius`, `theme.space.md`,
`theme.bodyFont()`. `ThemeHRule` / `ThemeVRule` replace `Divider()`, which
draws the system separator and does not flip.

**Fonts are requests, backed by files the app ships.** A `ThemeFontFace`
names families in preference order and falls back to its `design` when none is
installed. The built-ins ask for Zed's pair — IBM Plex Sans for display and
body, Lilex for mono and numerals — and the app bundles both: the `.ttf`s and
their SIL OFL licences live in `Priority/Fonts/`, the synchronized group copies
them into Resources, and `BundledFonts.register()` registers them for the
process from `AppDelegate.init`, before any surface draws. `Theme.font` and its
AppKit twin `Theme.nsFont` share one resolver, which picks the family's real
face at each weight rather than thickening the regular one. A user theme can
name any installed family instead.

**What renders through it today.** The Eisenhower matrix, and the persistent
shell chrome: the dock row, the resize strip, the sync readout, the top bevel,
the breadcrumb bar and the scope chip. Everything else — the task list, the
kanban board, the daily view, the focus session, settings — still resolves
colour through `AppThemeColorToken` and `PreferencesManager.themeColor(for:)`,
which is the older per-token override mechanism and is unrelated to this
plugin. Both are live at once on purpose; a surface is migrated when its
`themeColor(_:)` helper is gone.

## Verification

After plugin changes, run:

```bash
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build
swift test
```
