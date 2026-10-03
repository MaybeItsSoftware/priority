#!/usr/bin/env bash
set -euo pipefail

# Builds Release and replaces the installed app in /Applications.
#
# Unlike `build_dmg.sh` this skips the DMG, Finder scripting, and notarization —
# none of which matter for putting a build on the machine that produced it.
#
# The existing app is moved aside rather than deleted, and /Applications is only
# touched *after* a successful build, so a compile failure can never leave you
# without a working app.
#
# Exactly one backup is kept. It used to keep every one it ever made, which came
# to 389MB of superseded builds inside the repo's own tree — a rollback you would
# use is the one from the install you just replaced, and the fifteen before it
# are only disk.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEPROJ="$ROOT_DIR/Priority.xcodeproj"
# The scheme keeps the code's name; the product it builds is Takt.
SCHEME="Priority"
APP_NAME="Takt.app"
PROCESS_NAME="Takt"
INSTALL_PATH="/Applications/$APP_NAME"
# The app was called Priority until it became Takt. An install of it is
# quit and moved into the backup folder below, so there are never two apps
# sharing one workspace in /Applications.
LEGACY_INSTALL_PATH="/Applications/Priority.app"
LEGACY_PROCESS_NAME="Priority"

BUILD_DIR="$ROOT_DIR/build"
DERIVED_DIR="/tmp/takt-derived-install"
# `.noindex`, so Spotlight and Launch Services never offer the backup as a
# second "Takt" beside the installed one.
BACKUP_DIR="$BUILD_DIR/backup.noindex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BACKUP_PATH="$BACKUP_DIR/$APP_NAME.$(date +%Y%m%d-%H%M%S)"

echo "==> Building Release…"
rm -rf "$DERIVED_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  -destination 'platform=macOS' \
  build

APP_PATH="$DERIVED_DIR/Build/Products/Release/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build reported success but no app bundle at: $APP_PATH" >&2
  exit 1
fi

echo "==> Quitting any running instance…"
for name in "$PROCESS_NAME" "$LEGACY_PROCESS_NAME"; do
  osascript -e "tell application \"$name\" to quit" 2>/dev/null || true
done
sleep 1
killall "$PROCESS_NAME" "$LEGACY_PROCESS_NAME" 2>/dev/null || true

if [[ -d "$INSTALL_PATH" ]]; then
  echo "==> Backing up the installed app to $BACKUP_PATH"
  mkdir -p "$BACKUP_DIR"
  # `ditto` rather than `cp -R` so bundle metadata and symlinks survive intact.
  ditto "$INSTALL_PATH" "$BACKUP_PATH"
  "$LSREGISTER" -u "$BACKUP_PATH" 2>/dev/null || true
  rm -rf "$INSTALL_PATH"
  # Everything older than the backup just taken.
  find "$BACKUP_DIR" -maxdepth 1 -name "$APP_NAME.*" ! -name "$(basename "$BACKUP_PATH")" \
    -exec rm -rf {} +
fi

if [[ -d "$LEGACY_INSTALL_PATH" ]]; then
  # Moved, not deleted, and kept apart from the Takt backups so the prune
  # above never takes it: it is the way back if the rename went wrong. Its
  # data is untouched — Takt copies it on first launch and leaves the
  # original where it was.
  LEGACY_BACKUP_PATH="$BACKUP_DIR/Priority.app.$(date +%Y%m%d-%H%M%S)"
  echo "==> Moving the old Priority.app to $LEGACY_BACKUP_PATH"
  mkdir -p "$BACKUP_DIR"
  ditto "$LEGACY_INSTALL_PATH" "$LEGACY_BACKUP_PATH"
  "$LSREGISTER" -u "$LEGACY_INSTALL_PATH" 2>/dev/null || true
  "$LSREGISTER" -u "$LEGACY_BACKUP_PATH" 2>/dev/null || true
  rm -rf "$LEGACY_INSTALL_PATH"
fi

echo "==> Installing to $INSTALL_PATH"
ditto "$APP_PATH" "$INSTALL_PATH"

# The build is locally signed, so strip any quarantine attribute rather than
# letting Gatekeeper block first launch.
xattr -cr "$INSTALL_PATH" 2>/dev/null || true

echo "==> Launching…"
open "$INSTALL_PATH"

echo
echo "Installed. Previous version kept at:"
echo "  $BACKUP_PATH"
echo
echo "To roll back:"
echo "  killall '$PROCESS_NAME'; rm -rf '$INSTALL_PATH' && ditto '$BACKUP_PATH' '$INSTALL_PATH' && open '$INSTALL_PATH'"
