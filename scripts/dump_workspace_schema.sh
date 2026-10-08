#!/usr/bin/env bash
# Regenerate cli/src/fixtures/workspace_schema.sql, the workspace schema as DDL
# only, never a row of data, from the Rust core's migrations (core/src/schema).
#
# The CLI's workspace-write tests build their databases from it, Android's
# schema test compares against it, and the core's own test asserts a database
# it migrates dumps to exactly this file. It needs the real triggers in
# particular: the `change_log` triggers that make a write undoable and the
# FTS5 triggers that keep search level with the tasks table.
#
# Run after adding a migration to core/src/schema:
#
#   scripts/dump_workspace_schema.sh
#
# Or, to see what an existing database looks like once migrated, pass its path.
# It is copied first; the original is never opened for writing.
#
#   scripts/dump_workspace_schema.sh path/to/priority.sqlite > /tmp/schema.sql
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/cli/src/fixtures/workspace_schema.sql"
dump=(cargo run -q --manifest-path "$root/core/Cargo.toml" --example dump_schema --)

if [[ $# -gt 0 ]]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  sqlite3 "file:$1?mode=ro" ".backup '$scratch/copy.sqlite'"
  "${dump[@]}" "$scratch/copy.sqlite"
  exit 0
fi

mkdir -p "$(dirname "$output")"
"${dump[@]}" > "$output"
echo "Wrote $output ($(grep -m1 -o 'as of [^.]*' "$output"))"
