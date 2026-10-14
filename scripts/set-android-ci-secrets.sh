#!/usr/bin/env bash
#
# set-android-ci-secrets.sh — give .github/workflows/android-internal.yml what
# it needs to sign and upload to Play internal testing.
#
# Usage:   ./scripts/set-android-ci-secrets.sh [path/to/.env with PLAY_STORE_SERVICE_ACCOUNT_JSON]
#
# The signing key is Takt's own upload key, read from the gitignored
# mobile/android/keystore.properties: Takt's Play listing is tied to that key,
# not the shared maybeitssoftware one. The Play service account is the shared
# deployer, taken from another app's .env (default ../open-parliament/.env).
#
# Every value is piped to `gh secret set` on stdin, so none appears in process
# arguments or shell history. This script holds no secret values.

set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "error: gh CLI not installed." >&2; exit 1; }
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
ENV_FILE="${1:-../open-parliament/.env}"
KP=mobile/android/keystore.properties

[ -f "$KP" ] || { echo "error: $KP not found." >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found." >&2; exit 1; }

# One value, split on the first '=' only (base64 and JSON contain '=').
prop() { grep -m1 "^$1=" "$2" | cut -d= -f2- | tr -d '\n'; }

store="$(prop storeFile "$KP")"
for candidate in "$store" "mobile/android/app/$store" "mobile/android/$store"; do
  [ -f "$candidate" ] && { KEYSTORE="$candidate"; break; }
done
[ -n "${KEYSTORE:-}" ] || { echo "error: keystore '$store' not found." >&2; exit 1; }

echo "Target repository: $REPO"
base64 -i "$KEYSTORE" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 --repo "$REPO"
prop storePassword "$KP" | gh secret set KEYSTORE_PASSWORD --repo "$REPO"
prop keyAlias "$KP" | gh secret set KEY_ALIAS --repo "$REPO"
prop keyPassword "$KP" | gh secret set KEY_PASSWORD --repo "$REPO"
prop PLAY_STORE_SERVICE_ACCOUNT_JSON "$ENV_FILE" | gh secret set PLAY_STORE_SERVICE_ACCOUNT_JSON --repo "$REPO"

echo
gh secret list --repo "$REPO"
