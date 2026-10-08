#!/usr/bin/env bash
# Builds the Rust core (core/) for Android and generates its Kotlin bindings:
#
#   mobile/android/data/src/main/jniLibs/<abi>/libtakt_core.so   (not committed)
#   mobile/android/core/src/main/java/uniffi/takt_core/          (committed)
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

# The core links androidx's SQLite (libsqliteJni.so, which exports the whole
# C API) instead of bundling its own, so the app runs one SQLite library: two
# copies sharing a file can release each other's locks and corrupt it. Gradle
# unpacks those libraries and passes their folder in; run standalone, this
# finds the AAR in Gradle's cache.
if [[ -z "${TAKT_SQLITE_JNI_DIR:-}" ]]; then
  version=$(sed -nE 's/^sqlite = "([^"]+)"/\1/p' "$ROOT_DIR/mobile/android/gradle/libs.versions.toml")
  aar=$(find "$HOME/.gradle/caches" -path "*sqlite-bundled-android/$version/*" -name "*.aar" 2>/dev/null | head -1)
  if [[ -z "$aar" ]]; then
    echo "error: androidx sqlite-bundled-android $version is not in Gradle's cache; build once with ./gradlew first." >&2
    exit 1
  fi
  TAKT_SQLITE_JNI_DIR=$(mktemp -d)
  unzip -q -o "$aar" 'jni/*/libsqliteJni.so' -d "$TAKT_SQLITE_JNI_DIR.tmp"
  mv "$TAKT_SQLITE_JNI_DIR.tmp/jni/"* "$TAKT_SQLITE_JNI_DIR/"
  rm -rf "$TAKT_SQLITE_JNI_DIR.tmp"
fi

# libsqlite3-sys links a library called sqlite3; a copy named that, carrying
# libsqliteJni.so's SONAME, makes the core's .so need libsqliteJni.so at run
# time, which the app already ships beside it.
link_dir=$(mktemp -d)
trap 'rm -rf "$link_dir"' EXIT
for abi in arm64-v8a armeabi-v7a x86_64; do
  mkdir -p "$link_dir/$abi"
  cp "$TAKT_SQLITE_JNI_DIR/$abi/libsqliteJni.so" "$link_dir/$abi/libsqlite3.so"
  echo "takt-core: android $abi"
  # minSdk 29 matches mobile/android/data/build.gradle.kts.
  (cd "$CORE" && SQLITE3_LIB_DIR="$link_dir/$abi" SQLITE3_STATIC=0 \
    cargo ndk -q -P 29 -t "$abi" -o "$DATA/jniLibs" build $FLAG --lib)
done

# The host library: the JVM unit tests load it, and bindgen reads its metadata.
echo "takt-core: host"
cargo build -q $FLAG --manifest-path "$CORE/Cargo.toml" --lib
case "$(uname)" in
  Darwin) host_lib="$CORE/target/$PROFILE/libtakt_core.dylib" ;;
  *) host_lib="$CORE/target/$PROFILE/libtakt_core.so" ;;
esac

gen=$(mktemp -d)
trap 'rm -rf "$gen" "$link_dir"' EXIT
(cd "$CORE" && cargo run -q --features bindgen --bin uniffi-bindgen -- \
  generate --library "$host_lib" --language kotlin --no-format --out-dir "$gen")
# The bindings live in :core, the plain Kotlin module the rest builds on, so
# its ranking and availability rules can call the Rust core too. The native
# libraries stay in :data, the Android library that ships them.
BINDINGS="$ROOT_DIR/mobile/android/core/src/main/java"
rm -rf "$BINDINGS/uniffi"
mkdir -p "$BINDINGS"
cp -R "$gen/uniffi" "$BINDINGS/"

echo "takt-core: jniLibs, Kotlin bindings, host library at $host_lib"
