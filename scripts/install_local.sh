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
SCHEME="Priority"
APP_NAME="Priority.app"
INSTALL_PATH="/Applications/$APP_NAME"

BUILD_DIR="$ROOT_DIR/build"
DERIVED_DIR="/tmp/priority-derived-install"
BACKUP_DIR="$BUILD_DIR/backup"
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
osascript -e 'tell application "Priority" to quit' 2>/dev/null || true
sleep 1
killall "Priority" 2>/dev/null || true

if [[ -d "$INSTALL_PATH" ]]; then
  echo "==> Backing up the installed app to $BACKUP_PATH"
  mkdir -p "$BACKUP_DIR"
  # `ditto` rather than `cp -R` so bundle metadata and symlinks survive intact.
  ditto "$INSTALL_PATH" "$BACKUP_PATH"
  rm -rf "$INSTALL_PATH"
  # Everything older than the backup just taken.
  find "$BACKUP_DIR" -maxdepth 1 -name "$APP_NAME.*" ! -name "$(basename "$BACKUP_PATH")" \
    -exec rm -rf {} +
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
echo "  killall 'Priority'; rm -rf '$INSTALL_PATH' && ditto '$BACKUP_PATH' '$INSTALL_PATH' && open '$INSTALL_PATH'"
