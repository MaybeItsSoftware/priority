#!/usr/bin/env bash
# Build the Wear OS companion's App Bundle for the Play Console, beside the
# phone's from scripts/build_play_bundle.sh.
#
#   scripts/build_wear_bundle.sh [versionName]
#
# Same upload key as the phone (mobile/android/keystore.properties): the
# Wearable Data Layer only pairs the two apps when their signatures match.
#
# versionCode is the phone's (the commit count on HEAD, or TAKT_VERSION_CODE)
# plus 1,000,000,000, added by mobile/android/wear/build.gradle.kts, so the
# watch's code never equals a phone code Play has seen (docs/wear-os.md).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
android="$root/mobile/android"
version_name="${1:-$(grep -m1 'versionName' "$android/app/build.gradle.kts" | sed -E 's/.*"(.*)".*/\1/')}"
phone_code="${TAKT_VERSION_CODE:-$(git -C "$root" rev-list --count HEAD)}"
wear_code=$((phone_code + 1000000000))

if [[ ! -f "$android/keystore.properties" ]]; then
  echo "error: mobile/android/keystore.properties is missing, so the bundle would be signed with the debug key, which Play rejects." >&2
  exit 1
fi

echo "Building Takt for Wear OS $version_name ($wear_code)"
cd "$android"
./gradlew --no-daemon -q \
  -PversionCode="$phone_code" -PversionName="$version_name" \
  :wearcontract:test :wear:testDebugUnitTest :wear:lintRelease :wear:bundleRelease

bundle="$android/wear/build/outputs/bundle/release/wear-release.aab"
out_dir="$root/build/play"
mkdir -p "$out_dir"
out="$out_dir/takt-wear-$version_name-$wear_code.aab"
cp "$bundle" "$out"

# A debug-signed bundle is the one mistake Play reports only after the upload.
if jarsigner -verify -verbose -certs "$out" 2>/dev/null | grep -q 'CN=Android Debug'; then
  echo "error: $out is signed with the debug key." >&2
  exit 1
fi
jarsigner -verify "$out" >/dev/null

echo "Signed bundle: $out ($(du -h "$out" | cut -f1))"
