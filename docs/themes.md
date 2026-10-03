# Themes

Priority's look is a theme: a colour palette and a set of structural values
(radii, borders, spacing, type) under a name. Two ship with the app — **Chalk**,
the house style, which follows your Light/Dark setting, and **Chalk Dark** — and
you can add your own the way Zed does: as JSON files in a folder.

```
~/Library/Application Support/Priority/themes/*.json
```

Every `.json` file there is a theme. It appears in **Settings → Theme** beside
Chalk and Chalk Dark, and the app reloads it as you save it. If the theme you
are using is edited, the window redraws; if its file disappears or stops
loading, Chalk stands in until it comes back.

## Getting started

The quickest way in is from the command palette (`⌘K`):

- **Export the current theme as JSON** writes the theme you are using to the
  folder as a complete file — every colour and size spelled out — opens it in
  your editor, and switches to it. Whatever you change in it shows up as soon
  as you save.
- **Open the themes folder** reveals the folder in Finder, creating it if it
  is missing.
- **Reload themes** re-reads the folder. It reloads by itself when a file is
  saved; this is for when it did not.

The same three are buttons under **Your themes** in the theme settings page,
which also lists every problem found in the files.

## A theme can be a few lines

Every field is optional. Anything a file leaves out comes from the theme it
**extends**, which is Chalk unless it says otherwise. This is a complete theme:

```json
{
  "name": "Chalk, violet",
  "palette": {
    "light": { "primary": "#7a4de8" },
    "dark": { "primary": "#9b7bf0" }
  }
}
```

So is this, which is Chalk Dark with bigger type and the softer, rounded
look the app had before it went square:

```json
{
  "name": "Big Dark",
  "extends": "native.theme.chalk.dark",
  "structure": {
    "radius": { "panel": 8, "row": 6, "control": 6 },
    "typography": { "bodySize": 15 }
  }
}
```

## The full format

This is what **Export** writes for Chalk, reordered for reading. Every value
is stated, so it is also a reference for what can be set.

```json
{
  "identifier": "user.chalk-copy",
  "name": "Chalk copy",
  "summary": "Exported from Chalk. Edit freely; see docs/themes.md.",
  "lockedAppearance": null,
  "palette": {
    "light": {
      "paper": "#faf8f4",
      "raised": "#ffffff",
      "altRow": "#f5f3f1",
      "hover": "#f1eff1",
      "well": "#edebef",
      "border": "#e6e4ea",
      "borderMuted": "#efedf2",
      "inputBorder": "#d8d5dd",
      "ink": "#444054",
      "mutedText": "#6e6b7c",
      "dimText": "#b6b3bf",
      "primary": "#007fff",
      "success": "#4cc38e",
      "danger": "#d62246",
      "warning": "#ffbf00",
      "categoricalPurple": "#7a4de8",
      "categoricalPink": "#ff88dc",
      "categoricalOrange": "#ff6b2b",
      "mediaLetterbox": "#000000",
      "mediaScrim": "#000000b3",
      "mediaScrimInk": "#ffffff"
    },
    "dark": {
      "paper": "#1c1a23",
      "raised": "#25232f",
      "altRow": "#211f29",
      "hover": "#2d2b38",
      "well": "#2d2b38",
      "border": "#34313f",
      "borderMuted": "#2d2b38",
      "inputBorder": "#403d4d",
      "ink": "#f5f4f7",
      "mutedText": "#b6b3bf",
      "dimText": "#6e6b7c",
      "primary": "#007fff",
      "success": "#4cc38e",
      "danger": "#d62246",
      "warning": "#ffbf00",
      "categoricalPurple": "#7a4de8",
      "categoricalPink": "#ff88dc",
      "categoricalOrange": "#ff6b2b"
    }
  },
  "structure": {
    "radius": { "panel": 0, "row": 0, "control": 4, "pill": 9999, "shell": 20 },
    "border": { "hairline": 1, "emphasis": 2, "focusRing": 2 },
    "spacing": { "xxs": 2, "xs": 4, "sm": 8, "md": 12, "lg": 16, "xl": 24 },
    "typography": {
      "display": { "families": ["IBM Plex Sans"], "design": "sans" },
      "body": { "families": ["IBM Plex Sans"], "design": "sans" },
      "mono": { "families": ["Lilex"], "design": "monospaced" },
      "bodySize": 13,
      "scale": { "caption": 12, "body": 13, "title": 15, "display": 28, "hero": 64 },
      "microLabel": {
        "size": 12,
        "weight": "regular",
        "tracking": 0,
        "uppercase": false,
        "role": "mutedText"
      }
    },
    "usesShadows": false,
    "usesGradientsOnChrome": false
  }
}
```

### Identity

| Key | Meaning |
| --- | --- |
| `identifier` | What the app stores as your choice. Optional: a file without one is `user.<file name>`, so `dusk.json` is `user.dusk`. It cannot be a built-in's (`native.theme.chalk`, `native.theme.chalk.dark`), and two files cannot share one — the second, in file-name order, is skipped. |
| `name` | Shown in the picker. Defaults to the file name. Not inherited. |
| `summary` | Shown under the picker. Not inherited. |
| `extends` | The identifier of the theme to take every unstated value from: a built-in, or another of your files (in any order; a cycle is reported and both are skipped). Leave it out for Chalk. `null` inherits no colours at all — see [Missing roles](#missing-roles). |
| `lockedAppearance` | `"light"` or `"dark"` makes the theme *be* that appearance whatever the system is set to, the way Chalk Dark does. `null` clears an inherited lock, so a theme extending Chalk Dark can follow the system again. Leave it out to inherit. |

### Palette

`palette.light` and `palette.dark` map a **role** to a colour. Components only
ever name a role, never a hex value, so changing a role changes everything
drawn in it. A role you leave out keeps the value of the theme you extend, in
that appearance.

Colours are `#rgb`, `#rrggbb` or `#rrggbbaa` (the last two digits are alpha:
`#000000b3` is black at 70%).

| Role | Used for |
| --- | --- |
| `paper` | The page. |
| `raised` | Cards and panels, half a step above the page. |
| `altRow` | Alternating rows. |
| `hover` | Hover feedback on a row or control. |
| `well` | Wells, chips and inset containers. |
| `border` | The hairline that does the separating. |
| `borderMuted` | A softer hairline, for dividers inside a surface. |
| `inputBorder` | The stronger hairline an editable field needs. |
| `ink` | Body text and icons. |
| `mutedText` | Captions, micro-labels, status lines. |
| `dimText` | Placeholders and disabled glyphs — never anything you must read. |
| `primary` | Actions, links, focus rings, selection, "info". |
| `success`, `danger`, `warning` | The rest of the four-way status convention. |
| `categoricalPurple`, `categoricalPink`, `categoricalOrange` | Identity colour for charts, avatars and per-item hues. Never chrome. |
| `mediaLetterbox`, `mediaScrim`, `mediaScrimInk` | Behind and over photos. These do not flip with the appearance: they are read from `light` only, whatever is in force. |

Selection fills and status tints are made from these at low alpha where they
are drawn, so a new `primary` gives you a new selection colour too.

### Structure

All sizes are in points. Each group can be given in part.

| Key | Meaning |
| --- | --- |
| `radius.panel` | Cards, panels, popovers and overlays. The built-ins set 0, the way Zed draws them. |
| `radius.row` | A list row's selection and hover — sidebar, outline, Today, result lists. Rows run edge to edge of their pane, so the built-ins set 0 and a selection is a full-width band; raise it for inset, rounded selections. |
| `radius.control` | Buttons, inputs, chips, tooltips. Should not exceed `panel`, unless `panel` is 0 — square panels with slightly rounded buttons is the built-in look. |
| `radius.pill` | Genuinely round things: avatars, dots, toggle knobs. Keep it large (999 or more). |
| `radius.shell` | The outermost window shell only. 18–22, or 0 for none. |
| `border.hairline` | The default rule. Above 2 is reported: that is a border, not a hairline. |
| `border.emphasis` | A selected or active edge. |
| `border.focusRing` | The focus ring, drawn in `primary`. |
| `spacing.xxs` … `spacing.xl` | The six-step spacing scale every padding comes from. Shrink them all for a denser app. |
| `typography.display`, `.body`, `.mono` | A face: `families`, tried in order, and `design` — `serif`, `sans`, `monospaced` or `rounded` — used when none of the families is installed. A family is a request: Priority bundles IBM Plex Sans and Lilex (the faces Zed ships), and anything else has to be installed on the Mac. Each weight uses the family's own face where it has one. |
| `typography.bodySize` | The base text size. Changing it without giving a `scale` re-proportions the whole scale from it, so one number makes everything bigger. |
| `typography.scale` | The named sizes views ask for: `caption`, `body`, `title`, `display` (large numerals) and `hero` (the focus timer). Any you state win over the proportioned ones. |
| `typography.microLabel` | The small label on section headers, column heads, tabs and chips: `size`, `weight` (`regular`, `medium`, `semibold`, `bold`, `black`), `tracking` in em, `uppercase`, and the colour `role` it is set in. The built-ins set it the way Zed does — caption size, regular, untracked, as written. |
| `usesShadows`, `usesGradientsOnChrome` | Declarations for the audit. Nothing in the app draws either; setting one true is reported. |

### The old slab style

Chalk used to be set in Arvo, with 10pt bold capitals tracked at 0.15em for
its labels. It is Zed's IBM Plex Sans and Lilex now, with quiet sentence-case
labels, but the old look is a theme away:

```json
{
  "name": "Chalk, slab",
  "structure": {
    "typography": {
      "display": { "families": ["Arvo", "Rockwell"], "design": "serif" },
      "body": { "families": ["Arvo", "Rockwell"], "design": "serif" },
      "scale": { "caption": 11 },
      "microLabel": { "size": 10, "weight": "bold", "tracking": 0.15, "uppercase": true }
    }
  }
}
```

Arvo is not bundled, so without it installed this is Rockwell, the slab macOS
ships. The labels' text is written in sentence case and uppercased by the
theme, so it comes out as it did.

## Across the Mac, iPhone and Android

One theme file works on all three apps. The palette is the same everywhere:
a role is one colour whatever the device, so a theme you tuned on the Mac
looks like itself on the phone. Structure (sizes, radii, spacing) is not the
same everywhere, because 13pt body text is right at a desk and too small in the
hand. So a theme can say what changes per platform.

### `platforms`

```json
{
  "name": "Dusk",
  "palette": { "dark": { "paper": "#15131c" } },
  "structure": { "radius": { "control": 2 } },
  "platforms": {
    "ios": { "structure": { "typography": { "bodySize": 18 } } },
    "android": { "structure": { "spacing": { "md": 14 } } }
  }
}
```

`platforms.macos`, `platforms.ios` and `platforms.android` each hold a partial
`structure`, laid over the theme's own `structure` on that platform only. The
order a value is resolved in, latest winning:

1. The theme it extends, fully resolved **for this platform** (which includes
   that theme's own `platforms` block).
2. This theme's `structure`.
3. This theme's `platforms.<this platform>.structure`.

So a theme that only changes colours inherits each platform's sensible sizes
from Chalk, and a theme that sets `structure.typography.bodySize` sets it
everywhere unless a `platforms` entry says otherwise. Palette is not allowed
under `platforms`. A `palette` key there is a warning and is ignored, because
the point is that colour stays consistent.

### Chalk's defaults per platform

| | macOS | iOS | Android |
| --- | --- | --- | --- |
| `typography.bodySize` | 13 | 17 | 16 |
| `typography.scale` caption / body / title / display / hero | 12 / 13 / 15 / 28 / 64 | 13 / 17 / 20 / 34 / 72 | 12 / 16 / 20 / 32 / 72 |
| `typography.microLabel.size` | 12 | 13 | 12 |
| `radius` panel / row / control | 0 / 0 / 4 | 8 / 0 / 6 | 8 / 0 / 6 |
| `spacing` xxs … xl | 2 4 8 12 16 24 | 2 4 8 12 16 24 | 2 4 8 12 16 24 |
| `touchTarget` | 0 (pointer) | 44 | 48 |

Chalk Dark extends Chalk and so takes the same per-platform structure.

`touchTarget` is new in the structure: the minimum hit area a control is
grown to, invisibly, so the painted control keeps its size. 0 means a pointer
platform with no minimum.

### Built-ins are shared files

Chalk and Chalk Dark are defined once, in Swift
(`BuiltInThemeSpecifications`), and exported as complete JSON to
`shared/themes/chalk.json` and `shared/themes/chalk-dark.json`. A Swift test
fails if those files and the Swift definitions disagree; run it with
`PRIORITY_REGENERATE_THEMES=1` to rewrite them. The Android app reads those files
from its assets (a Gradle task copies them in, the same way it copies the
workspace schema), so the three apps cannot drift apart on a hex value.

`shared/themes/conformance/` holds resolution cases: input files plus the
expected resolved theme for each platform and appearance. They are written by
the Swift tests, and the Kotlin resolver must reproduce them exactly.

### The chosen theme follows you

Your themes and your choice of theme sync with the rest of the workspace
(see [sync](sync.md)):

- Every user theme is a row in the synced `themes` table (`id` is its
  identifier, `json` the file's text). On the Mac the themes folder stays the
  place you edit. Saving a file updates its row, and deleting the file deletes the
  row. A theme that arrives from another device is written into the folder as
  `<identifier>.json`, unless a file already claims that identifier. A theme
  whose identifier comes from its file name (`user.dusk`, from a `dusk.json`
  with no `identifier`) is written back under that name instead, `dusk.json`,
  so it is the same theme on the Mac. An edit from another device is
  written into the file if the file has not changed here since. If both
  changed, the Mac's file wins. A theme removed on another device moves its
  file to the Trash, unless the file has been edited here since. While any
  file in the folder is not valid JSON, the Mac writes and removes nothing,
  because a file half way through an edit does not say which theme it is. On the
  phones, **Settings → Theme → Import** adds a row from a `.json` file, and a
  theme can be removed there.
- The choice of theme and appearance (`theme.selected`, `theme.appearance`:
  `system`, `light` or `dark`) are rows in the synced `preferences` table. Each
  device can opt out with **Use a different theme on this device** (on the
  Mac, **Use a different theme on this Mac** in Settings → Theme), which is
  stored locally and not synced. Turning it on keeps the theme the device is
  showing, and from then on changes stay on that device. Turning it off
  takes up the synced choice again. The first time a Mac with this feature opens
  the workspace, its current theme and appearance become the synced choice,
  unless another device has already set one.
- A device that does not know the chosen theme (it failed to load there, or
  has not arrived yet) shows Chalk until it does.

## When something is wrong

A theme file is never all-or-nothing, and never stops the app starting.

- **A bad value** — a hex that is not a colour, an unknown `design` or
  `weight`, a negative size — is reported as an error and skipped; the value
  it would have replaced stays. The theme still loads.
- **An unknown key or role** — `"pallete"`, `"backgroud"` — is a warning and is
  ignored. It is worth reading these: a misspelt key otherwise does nothing,
  silently.
- **A file that is not JSON**, or has a string where a number goes, is skipped
  with the reason and the path (`structure.radius.panel should be a number`).
- **An `extends` that names nothing**, or a chain of them that loops, skips the
  file.

Errors appear on the window's status line and in **Diagnostics**, under
*Themes*; warnings go to Diagnostics only. The theme settings page lists them
all, per file.

Every theme that loads is also put through the same audit as the built-ins,
and the result is on the settings page under **Audit**: body text under 4.5:1
against the page is a warning, `primary` under 3:1 is a warning (it has to
carry the focus ring), and an accent under 4.5:1 is a *note* — fine for
headlines, fills and controls, not for a paragraph. Azure on Chalk's paper is
3.6:1, which is why Chalk itself has notes.

### Missing roles

With the default `extends`, every role always has a value. A theme with
`"extends": null` starts from nothing, so it has to give each role itself. A
role missing from one table is borrowed from the other and reported as an
error; a role missing from **both** would draw as debug magenta, so that theme
is skipped (`not loaded: no colour for categoricalPink`). Structure is never
missing: without a base it falls back to Chalk's.

## For developers

The format is decoded in `PriorityCore`
(`Sources/PriorityCore/Theming/ThemeFile.swift` and `ThemeFileLoader.swift`)
and tested in `corelogic-tests/ThemeFileTests.swift`.

- **Platforms.** `ThemeFileLoader.load(_:platform:)` resolves a folder for
  one `ThemePlatform` (`.macos`, `.ios`, `.android`). The default is `.macos`,
  so the Mac reads exactly as it did before platforms existed.
  `BuiltInThemeSpecifications.chalk(for:)`, `chalkDark(for:)`, `all(for:)` and
  `specification(withIdentifier:for:)` are the built-ins per platform. The
  phones' differences from the Mac are `chalkPlatformStructures`, a partial
  `ThemeFile.Structure` per platform. `chalk` and `chalkDark` without a
  platform are the Mac's. `ThemeStructureAudit` warns about a `touchTarget`
  between 0 and 44.
- **Shared files.** `ThemeConformance` (in `PriorityCore`) builds the
  complete built-in files and the canonical resolved form, and
  `corelogic-tests/ThemeConformanceTests.swift` holds `shared/themes/` to it:
  the cases are listed in that test. Add a case there, then regenerate with
  `PRIORITY_REGENERATE_THEMES=1 swift test --filter PriorityCoreTests.ThemeConformanceTests`.
  The format is in [`shared/themes/README.md`](../shared/themes/README.md).
- **Sync.** The rows are `WorkspaceStore.themes()`, `upsertTheme(id:json:)`,
  `deleteTheme(id:)`, `preference(_:)` and `setPreference(_:_:)`
  (`Sources/PriorityWorkspace/WorkspaceStore+Themes.swift`, migration
  `v18_themes_and_preferences`). Writes that change nothing are skipped, which
  is what keeps a row and a file from echoing each other. The keys are
  `WorkspacePreferenceKey.themeSelected` and `.themeAppearance`.
- **The Mac.** `UserThemeLibrary` watches the folder and vends a
  `UserThemePlugin` per file to `ThemeManager`. Once the workspace is open it
  also mirrors the folder into the `themes` table on every load. What to do is
  decided by `ThemeFolderMirror.plan` in `PriorityCore`, tested in
  `corelogic-tests/ThemeFolderMirrorTests.swift`. That compares each side
  with the digest of the text last mirrored, which is kept in `UserDefaults`.
  `ThemeChoiceSync` keeps `ThemeManager`'s pick and the appearance setting in
  step with the synced preferences, and owns the per-Mac opt-out.
  `AppDelegate` builds it once the workspace store exists. After a sync pull or
  a write from another process, `WorkspaceViewModel.reloadAfterExternalWrite`
  calls `onWorkspaceChangedElsewhere`, which reloads the themes and the
  choice.

See the Theme section of [`docs/plugins.md`](plugins.md).
