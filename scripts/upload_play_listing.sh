#!/usr/bin/env bash
# Uploads Takt's Play store listing: the text from docs/store-listing.md and
# the images from design/store (scripts/build_store_assets.sh frames them).
# No bundle and no release — the listing only, in en-GB.
#
#   scripts/upload_play_listing.sh --dry-run    # assemble build/play/listing only
#   PLAY_JSON_KEY_FILE=~/.config/takt/play-service-account.json scripts/upload_play_listing.sh
#
# The listing is public, so this replaces what the Play page shows.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/play/listing/en-GB"
rm -rf "$root/build/play/listing"
mkdir -p "$out/images/phoneScreenshots"

# The text, read out of the doc that says what to paste, so the two cannot
# drift: the name, Play's short description and the shared description.
python3 -I - "$root/docs/store-listing.md" "$out" <<'PY'
import re, sys, pathlib
doc = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
field = lambda label: re.search(r"\*\*" + re.escape(label) + r"\*\*[^\n]*?\n?`([^`]+)`", doc).group(1)
description = re.search(r"\*\*Description\*\* \[4000\]:\s*```\n(.*?)```", doc, re.S).group(1)
# Play reflows paragraphs; the doc's are wrapped at 76 columns for reading.
paragraphs = [re.sub(r"\n(?!•) *", " ", p.strip()) for p in description.strip().split("\n\n")]
(out / "title.txt").write_text(field("Name"))
(out / "short_description.txt").write_text(field("Short description"))
(out / "full_description.txt").write_text("\n\n".join(paragraphs))
for name in ("title", "short_description", "full_description"):
    limit = {"title": 30, "short_description": 80, "full_description": 4000}[name]
    text = (out / f"{name}.txt").read_text()
    assert 0 < len(text) <= limit, f"{name} is {len(text)} characters, over {limit}"
PY

cp "$root/design/logo/takt-icon-512.png" "$out/images/icon.png"
cp "$root/design/store/play-feature.png" "$out/images/featureGraphic.png"
cp "$root/design/store/android/"0*.png "$out/images/phoneScreenshots/"

# --dry-run stops here, to read build/play/listing before it goes public.
[[ "${1:-}" == "--dry-run" ]] && { find "$root/build/play/listing" -type f; exit 0; }

cd "$root/mobile/android"
bundle exec fastlane android listing metadata:"$root/build/play/listing"
