#!/bin/sh
# Build the JSON payload for a Konnect STREAMED custom-plugin upload.
#
# Why this exists: Konnect caps the `handler` field at 102,400 bytes, and it is a
# HARD limit -- the upload fails with
#   validation error: length must be <= 102400, but got 103976
# This handler carries an unusual amount of comment, on purpose: it records which
# defaults cost an outage, which Kong behaviours are undocumented, and why several
# non-obvious choices are the way they are. Deleting that to fit a wire limit
# would trade durable knowledge for bytes.
#
# So: keep the source fully commented, and strip comments only for the upload,
# which is machine-consumed. Measured 103,981 -> ~56,000 bytes, i.e. roughly 45%
# headroom restored.
#
# Only FULL-LINE comments and blank lines are removed. Trailing comments are left
# alone because stripping them needs real Lua lexing to avoid mangling a `--`
# inside a string literal. A line whose first non-space characters are `--` can
# still be a line inside a long-bracket string, so the caller MUST verify the
# stripped output (see `make bundle`, which runs the offline suite against it).
#
#   ./scripts/bundle-streamed-plugin.sh [output.json]
set -eu

PLUGIN_DIR="plugin/kong/plugins/skyflow-deidentify"
OUT="${1:-custom-plugin.json}"
LIMIT=102400

[ -f "$PLUGIN_DIR/handler.lua" ] || { echo "run from the repo root" >&2; exit 1; }

STRIPPED="$(mktemp)"
trap 'rm -f "$STRIPPED"' EXIT

# sed, not a Lua-aware tool, so this stays dependency-free in CI:
#   1. delete lines whose first non-blank characters are --
#   2. delete now-empty lines
sed -e '/^[[:space:]]*--/d' -e '/^[[:space:]]*$/d' "$PLUGIN_DIR/handler.lua" > "$STRIPPED"

raw=$(wc -c < "$PLUGIN_DIR/handler.lua" | tr -d ' ')
new=$(wc -c < "$STRIPPED" | tr -d ' ')
echo "  handler: $raw -> $new bytes (limit $LIMIT)"
if [ "$new" -gt "$LIMIT" ]; then
  echo "FAIL: still over the Konnect limit by $((new - LIMIT)) bytes." >&2
  echo "      Comment stripping is no longer enough; the handler needs splitting" >&2
  echo "      or genuine code reduction." >&2
  exit 1
fi

# schema.lua is small and its comments document the Konnect upload constraints
# themselves, so it ships as-is.
sch=$(wc -c < "$PLUGIN_DIR/schema.lua" | tr -d ' ')
echo "  schema:  $sch bytes (unstripped)"

python3 - "$STRIPPED" "$PLUGIN_DIR/schema.lua" "$OUT" <<'PY'
import json, sys
handler, schema, out = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
    "name": "skyflow-deidentify",
    "schema": open(schema).read(),
    "handler": open(handler).read(),
}, open(out, "w"))
PY
echo "  wrote $OUT"
