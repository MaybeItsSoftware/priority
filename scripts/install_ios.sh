#!/usr/bin/env bash
# Build the iOS app (Release) and install it.
#
#   ./scripts/install_ios.sh                 # iPhone 17 Pro simulator, booted on demand
#   DEVICE_ID=<udid> ./scripts/install_ios.sh   # a connected device (xcrun devicectl list devices)
#   SIMULATOR="iPad Pro 13-inch (M5)" ./scripts/install_ios.sh
#
# Regenerates the Xcode project with XcodeGen first; the .xcodeproj is not
# committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/mobile/ios"
BUNDLE_ID="uk.co.maybeitssoftware.takt"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
DERIVED="$IOS/build/install"

command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
(cd "$IOS" && xcodegen --quiet)

build() {
  local destination="$1"
  local log
  log="$(mktemp)"
  if ! xcodebuild -project "$IOS/PriorityMobile.xcodeproj" -scheme PriorityMobile -configuration Release \
      -destination "$destination" -derivedDataPath "$DERIVED" build >"$log" 2>&1; then
    grep -E "error:" "$log" | sort -u >&2 || true
    echo "** BUILD FAILED ** (full log: $log)" >&2
    exit 1
  fi
  echo "** BUILD SUCCEEDED **"
}

if [[ -n "${DEVICE_ID:-}" ]]; then
  build "id=$DEVICE_ID"
  APP="$DERIVED/Build/Products/Release-iphoneos/Takt.app"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || true
  echo "Installed on $DEVICE_ID."
  exit 0
fi

UDID="$(xcrun simctl list devices available | grep -F "    $SIMULATOR (" | grep -oE '[0-9A-F-]{36}' | head -1)"
[[ -n "$UDID" ]] || { echo "No simulator named '$SIMULATOR'." >&2; exit 1; }
if ! xcrun simctl list devices | grep -F "$UDID" | grep -q Booted; then
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null
fi
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true

build "id=$UDID"
APP="$DERIVED/Build/Products/Release-iphonesimulator/Takt.app"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
echo "Installed on $SIMULATOR."
