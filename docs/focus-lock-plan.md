# Focus lock — setup brief

A brief for later work, not a description of anything built. Written
2026-10-15.

## The ask

While a focus block runs, the Mac should hold you in it: no three-finger
swipe to another desktop, no ⌘-Tab, and — at the least — no other app
coming to the front. Ending the block (or the session) lets go.

## What macOS allows a sandboxed app

Takt is sandboxed (`Takt/Takt.entitlements`, `Takt.release.entitlements`),
which decides most of this.

- **Kiosk presentation options** (`NSApplication.shared.presentationOptions`)
  work in the sandbox. The relevant set:
  - `.hideDock` (or `.autoHideDock`) — required by the next one.
  - `.disableProcessSwitching` — turns off ⌘-Tab; Apple documents it as also
    disabling Exposé, i.e. Mission Control.
  - `.hideMenuBar`, `.disableAppleMenu`, `.disableHideApplication`.
  - `.disableForceQuit`, `.disableSessionTermination` — powerful; see the
    escape hatch below before using them.
  Options only apply while Takt is the active app, and the combinations are
  validated: an invalid set throws an Objective-C exception, so set them
  inside a single tested helper.
- **Desktop swiping** is the unknown. With the window full screen and the
  options above it may already be blocked; verify on the real trackpad before
  designing around it. If it is not, there is no public API to disable the
  gesture, and the fallback is the next point.
- **Other apps.** The sandbox will not let Takt quit or hide another app.
  It *can* watch `NSWorkspace.didActivateApplicationNotification` /
  `didLaunchApplicationNotification` and immediately reactivate itself, so an
  app can open but cannot stay in front. That is the realistic "keep apps
  from opening".
- **Worth checking before building:** whether Screen Time's ManagedSettings
  (app shielding) is available to a Mac app for its own user, and whether a
  `SetFocusFilterIntent` (system Focus filters) adds anything. Either could
  replace the reactivation loop with something the OS enforces.

## Proposed shape

- A preference, off by default: **Lock the Mac during focus blocks**, with an
  allow-list of apps (bundle ids) that may come to the front — a browser for
  research, a terminal.
- On block start: go full screen on the focus surface, apply the kiosk
  options, start the reactivation watcher. On block finish, stop, pause,
  break, or the app quitting: restore `presentationOptions` to `[]` and stop
  the watcher. Restoration must also run from `applicationWillTerminate` and
  on a crash-relaunch (a session found running with the lock preference on).
- **Escape hatch, required:** hold a key (say Esc for 3 seconds) to release
  the lock without ending the block, with a visible countdown. Never use
  `.disableForceQuit` without it.
- Breaks are not locked: the lock lifts when a break starts (see the break
  work in `WorkspaceViewModel+Focus.swift`).

## Where it would live

- A small `FocusLock` type in `Takt/Managers/` owning the options and the
  watcher; `WorkspaceViewModel+Focus.swift` calls it on the session's
  transitions. Nothing in the Rust core: this is Mac-only presentation.
- The preference in `PreferencesStore.swift`, its toggle beside the other
  focus settings.
- The phones are out of scope: iOS has Guided Access and Screen Time, and
  Android has screen pinning, each its own piece of work.

## Gates

The Mac ones in `CLAUDE.md` (`xcodebuild`, `swift test`, `swiftlint lint`),
then `./scripts/install_local.sh` and a manual check on the trackpad: swipe,
⌘-Tab, Mission Control, launching an app from Spotlight, and the escape hatch.
