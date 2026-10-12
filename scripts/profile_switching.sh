#!/usr/bin/env bash
# Records the running Takt for a while — the time profiler, frame hitches and
# the app's `Switching` signposts — so a slow switch can be read afterwards.
# Switch lists (or whatever is slow) while it runs. See docs/performance.md.
#
#   scripts/profile_switching.sh [seconds]    # default 30
set -euo pipefail

seconds="${1:-30}"
pid="$(pgrep -f '/Takt.app/Contents/MacOS/Takt$' | head -n 1 || true)"
if [[ -z "$pid" ]]; then
  echo "Takt isn't running." >&2
  exit 1
fi

output="/tmp/takt-switching.trace"
rm -rf "$output"
echo "Recording Takt ($pid) for ${seconds}s — switch lists now."
xcrun xctrace record --template 'Time Profiler' --instrument 'os_signpost' --instrument 'Hitches' \
  --attach "$pid" --time-limit "${seconds}s" --output "$output" >/dev/null
echo "Saved $output"
