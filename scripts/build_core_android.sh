#!/usr/bin/env bash
# Builds the Rust core (core/) for Android and generates its Kotlin bindings:
#
#   mobile/android/data/src/main/jniLibs/<abi>/libtakt_core.so   (not committed)
#   mobile/android/data/src/main/java/uniffi/takt_core/          (committed)
#
# plus a host build in core/target/<profile>/ that the data module's JVM unit
# tests load through JNA. Run after any change to core/;
# install_android.sh and build_play_bundle.sh call it first.
#
#   scripts/build_core_android.sh            release build (what the app ships)
#   PROFILE=debug scripts/build_core_android.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT_DIR/core"
DATA="$ROOT_DIR/mobile/android/data/src/main"
PROFILE=${PROFILE:-release}
FLAG=$([ "$PROFILE" = release ] && echo --release || true)

export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)
  export ANDROID_NDK_HOME
fi

# minSdk 29 matches mobile/android/data/build.gradle.kts.
echo "takt-core: android (arm64-v8a, armeabi-v7a, x86_64)"
(cd "$CORE" && cargo ndk -q -P 29 -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o "$DATA/jniLibs" build $FLAG --lib)

# The host library: the JVM unit tests load it, and bindgen reads its metadata.
echo "takt-core: host"
cargo build -q $FLAG --manifest-path "$CORE/Cargo.toml" --lib
case "$(uname)" in
  Darwin) host_lib="$CORE/target/$PROFILE/libtakt_core.dylib" ;;
  *) host_lib="$CORE/target/$PROFILE/libtakt_core.so" ;;
esac

gen=$(mktemp -d)
trap 'rm -rf "$gen"' EXIT
(cd "$CORE" && cargo run -q --features bindgen --bin uniffi-bindgen -- \
  generate --library "$host_lib" --language kotlin --no-format --out-dir "$gen")
rm -rf "$DATA/java/uniffi"
mkdir -p "$DATA/java"
cp -R "$gen/uniffi" "$DATA/java/"

echo "takt-core: jniLibs, Kotlin bindings, host library at $host_lib"
