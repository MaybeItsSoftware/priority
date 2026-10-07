#!/usr/bin/env bash
set -euo pipefail

# Builds the Rust CLI and installs it into the app bundle as a signed helper at
# `Contents/Helpers/takt`.
#
# This is what makes retiring the in-process MCP server safe. Client configs
# already on disk name the app's own executable with `--mcp-server`
# (`Takt.app/Contents/MacOS/Takt`); that binary now execs this helper, so the
# configs keep working without anyone having to install the CLI separately.
# See docs/mcp-server.md.
#
# Run from an Xcode build phase, so it reads the usual build settings. Set
# TAKT_SKIP_CLI_BUNDLE=1 to skip it — the app still builds and runs, but
# `--mcp-server` will have nothing to exec.

if [[ "${TAKT_SKIP_CLI_BUNDLE:-0}" == "1" ]]; then
  echo "note: TAKT_SKIP_CLI_BUNDLE=1 — the app will ship without an MCP server"
  exit 0
fi

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST="$ROOT_DIR/cli/Cargo.toml"
BINARY="$ROOT_DIR/cli/target/release/takt"

if ! command -v cargo >/dev/null 2>&1; then
  # Loudly, and with the fix. A quiet skip here produces an app whose MCP
  # server silently does nothing, which is far harder to diagnose than a
  # failed build.
  cat >&2 <<'MSG'
error: cargo is required to build Takt — the app bundles the `takt` CLI
       as its MCP server (Contents/Helpers/takt).

       Install Rust:  https://rustup.rs
       Or skip it:    TAKT_SKIP_CLI_BUNDLE=1 (the app will have no MCP server)
MSG
  exit 1
fi

# Release always, even for a Debug app: this is the shipping artifact, and it
# shares a target directory with scripts/install_cli.sh so the build stays warm.
cargo build --release --manifest-path "$MANIFEST"

if [[ ! -x "$BINARY" ]]; then
  echo "error: cargo reported success but no binary at $BINARY" >&2
  exit 1
fi

HELPERS_DIR="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
DEST="$HELPERS_DIR/takt"
mkdir -p "$HELPERS_DIR"
# -p preserves the timestamp so an unchanged helper doesn't invalidate the
# bundle on every build.
cp -p "$BINARY" "$DEST"

# Nested binaries have to be signed before Xcode signs the bundle around them;
# an unsigned one fails notarisation under the hardened runtime. So does one
# signed without a secure timestamp, so a real identity gets --timestamp (a
# network round trip to Apple's timestamp server); only the ad-hoc "-"
# identity, which can't be notarised anyway, uses --timestamp=none.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
if [[ "$IDENTITY" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP_FLAG" "$DEST"

echo "note: bundled $(basename "$BINARY") -> $DEST"
