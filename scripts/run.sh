#!/bin/bash
set -o pipefail

# Configuration
SCHEME="Takt"
PRODUCT="Takt"
CONFIG="Debug"
BUILD_DIR="$(pwd)/build"

# `SYMROOT` puts products at $BUILD_DIR/$CONFIG, so the binary's location is
# known up front. It used to be discovered with
#     find "$BUILD_DIR" -name "$PRODUCT" -type f -perm +111 | head -n 1
# which silently launched whatever `find` happened to walk into first — a stale
# Release build under build/rel/ (left by build_dmg.sh) or a build/backup.noindex/
# snapshot, both of which sort ahead of build/Debug/. The build would succeed
# and the *old* app would start, which looks exactly like a change not working.
APP_PATH="$BUILD_DIR/$CONFIG/$PRODUCT.app"
BINARY_PATH="$APP_PATH/Contents/MacOS/$PRODUCT"

echo "🚀 Building $PRODUCT ($CONFIG)..."

# Using -quiet to keep it clean since xcpretty is missing
if ! xcodebuild build \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -quiet \
    SYMROOT="$BUILD_DIR"; then
    echo "❌ Build Failed."
    exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
    echo "❌ Error: expected binary not found at $BINARY_PATH"
    echo "   (build reported success, so SYMROOT or the scheme's product name"
    echo "    has probably changed)"
    exit 1
fi

# Guard against launching something older than the sources. Cheap insurance
# against an incremental build that quietly no-op'd.
NEWER_SOURCE=$(find Takt -name '*.swift' -newer "$BINARY_PATH" -print -quit 2>/dev/null)
if [ -n "$NEWER_SOURCE" ]; then
    echo "❌ Error: $NEWER_SOURCE is newer than the built binary."
    echo "   The build did not pick up your changes. Try: rm -rf \"$BUILD_DIR/$CONFIG\""
    exit 1
fi

echo "✅ Build Succeeded."
echo "   Binary: $BINARY_PATH"
echo "   Built:  $(date -r "$BINARY_PATH" '+%Y-%m-%d %H:%M:%S')"

# Kill any running instance, including one launched from a different path (a
# previously-installed copy in /Applications, or an older build directory).
# The old name too, for an install of the app from before it was Takt.
pkill -f "$PRODUCT.app/Contents/MacOS/$PRODUCT" 2>/dev/null
pkill -f "Priority.app/Contents/MacOS/Priority" 2>/dev/null
sleep 0.5

echo "Running: $BINARY_PATH"

# Run in the foreground so os_log output and stdout land in this terminal and
# Ctrl-C quits the app — the reason this doesn't use `open`.
exec "$BINARY_PATH"
