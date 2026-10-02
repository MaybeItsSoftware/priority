#!/usr/bin/env bash
# Builds the Android app in release (R8, the baseline profile) and installs it
# on the connected device or running emulator, then launches it.
#
#   ./scripts/install_android.sh             # the only connected device
#   ANDROID_SERIAL=emulator-5554 ./scripts/install_android.sh
#
# Release is signed with mobile/android/keystore.properties when it exists,
# otherwise with the debug key (see mobile/android/app/build.gradle.kts).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project="$root/mobile/android"
adb="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
command -v adb >/dev/null 2>&1 && adb="$(command -v adb)"

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
  devices=$("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  count=$(printf '%s\n' "$devices" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "No device or emulator is connected. Start one, e.g.:" >&2
    echo "  ~/Library/Android/sdk/emulator/emulator -avd flutter_android &" >&2
    exit 1
  elif [[ "$count" -gt 1 ]]; then
    echo "More than one device is connected; choose one with ANDROID_SERIAL:" >&2
    printf '  %s\n' $devices >&2
    exit 1
  fi
  export ANDROID_SERIAL="$devices"
fi

(cd "$project" && ./gradlew :app:assembleRelease)
apk="$project/app/build/outputs/apk/release/app-release.apk"
[[ -f "$apk" ]] || { echo "No release APK at $apk" >&2; exit 1; }

echo "Installing on $ANDROID_SERIAL"
if ! "$adb" install -r "$apk"; then
  # A debug build signed with a different key blocks an in-place update.
  echo "In-place install failed; uninstalling the existing build and retrying." >&2
  "$adb" uninstall uk.co.maybeitsadam.priority >/dev/null || true
  "$adb" install "$apk"
fi
"$adb" shell am start -n uk.co.maybeitsadam.priority/.MainActivity >/dev/null
echo "Installed."
