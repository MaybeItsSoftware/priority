#!/usr/bin/env bash
set -euo pipefail

# Builds the Rust CLI in release and puts `takt` on your PATH.
#
# Symlinks rather than copies, so `git pull && cargo build --release` updates the
# installed command without re-running this. The link target is the build
# directory, which is why removing `cli/target` breaks the installed command
# rather than leaving a stale copy of an old build behind.
#
# Installs to the first writable directory that is already on PATH, so this
# never needs sudo and never quietly puts a binary somewhere you don't look.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT_DIR/cli/Cargo.toml"
BINARY="$ROOT_DIR/cli/target/release/takt"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is not installed. Get it from https://rustup.rs" >&2
  exit 1
fi

echo "==> Building the CLI (release)…"
cargo build --release --manifest-path "$MANIFEST"

if [[ ! -x "$BINARY" ]]; then
  echo "Build reported success but no binary at: $BINARY" >&2
  exit 1
fi

# Preference order: a user-local bin first, so nothing lands in a directory
# shared with Homebrew or the system.
for candidate in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
  if [[ -d "$candidate" && -w "$candidate" ]]; then
    INSTALL_DIR="$candidate"
    break
  fi
done

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo
  echo "Built, but found no writable bin directory to link into."
  echo "The binary is at:"
  echo "  $BINARY"
  echo
  echo "Put it on your PATH with, for example:"
  echo "  mkdir -p ~/.local/bin && ln -sf '$BINARY' ~/.local/bin/takt"
  exit 0
fi

ln -sf "$BINARY" "$INSTALL_DIR/takt"
echo
echo "Installed:  $INSTALL_DIR/takt -> $BINARY"

# The command was called `priority` before the product became Takt. Its old
# symlink points at `cli/target/release/priority`, which nothing builds any
# more, so it would go on running a frozen copy of an old build. Only a
# symlink into this repo's build tree is removed — a `priority` that is
# anything else is not ours to delete.
for candidate in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
  legacy="$candidate/priority"
  if [[ -L "$legacy" ]]; then
    case "$(readlink "$legacy")" in
      "$ROOT_DIR/cli/target/"*)
        rm -f "$legacy"
        echo "Removed the old command:  $legacy"
        ;;
    esac
  fi
done

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  # Only reachable if the directory existed but isn't on PATH — worth saying,
  # because the command would otherwise appear not to have installed at all.
  *) echo "NOTE: $INSTALL_DIR is not on your PATH. Add it to your shell profile." ;;
esac

echo
echo "Try:"
echo "  takt --help"
echo "  takt dailies"
