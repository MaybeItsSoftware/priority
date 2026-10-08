#!/usr/bin/env bash
# Build the iPhone app for App Store Connect (TestFlight, then the App Store).
#
#   scripts/build_app_store.sh            # archive and export build/app-store/Takt.ipa
#   scripts/build_app_store.sh --upload   # archive and upload straight to App Store Connect
#
# Signs automatically with the team in mobile/ios/project.yml, using the Apple
# Distribution certificate in your keychain. -allowProvisioningUpdates lets
# Xcode create the App Store profiles (and the App IDs' capabilities), which
# needs one of:
#
#   - an Apple ID signed in under Xcode → Settings → Accounts, or
#   - an App Store Connect API key (Users and Access → Integrations → Keys,
#     role App Manager), named by ASC_KEY_PATH (the .p8), ASC_KEY_ID and
#     ASC_ISSUER_ID.
#
# Uploading uses the same. The app has to exist in App Store Connect first,
# with bundle id uk.co.maybeitssoftware.takt (its widgets extension is
# uk.co.maybeitssoftware.takt.widgets).
#
# The build number must rise with every upload. It is the number of commits
# on HEAD, as for the Play bundle, so nobody has to remember to bump it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# The Swift package resolves only once the Rust core's xcframework exists
# (Package.swift `takt_coreFFI`); this rebuilds it when core/ changed.
TAKT_CORE_IF_STALE=1 "$root/scripts/build_core_apple.sh"
ios="$root/mobile/ios"
out="$root/build/app-store"
archive="$out/TaktMobile.xcarchive"
build_number="$(git -C "$root" rev-list --count HEAD)"
destination="export"
[[ "${1:-}" == "--upload" ]] && destination="upload"

auth=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID with ASC_KEY_PATH}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID with ASC_KEY_PATH}"
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

mkdir -p "$out"
(cd "$ios" && xcodegen generate >/dev/null)

options="$out/ExportOptions.plist"
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>6NQNU5YSC2</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "Archiving Takt for iPhone, build $build_number"
rm -rf "$archive"
xcodebuild -project "$ios/TaktMobile.xcodeproj" -scheme TaktMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive" -allowProvisioningUpdates "${auth[@]}" \
  CURRENT_PROJECT_VERSION="$build_number" \
  archive -quiet

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
  -exportOptionsPlist "$options" -allowProvisioningUpdates "${auth[@]}" -quiet

if [[ "$destination" == "upload" ]]; then
  echo "Uploaded build $build_number to App Store Connect; it appears in TestFlight once processed."
else
  echo "Exported: $out/Takt.ipa (build $build_number)"
fi
