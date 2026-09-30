#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/working-dir.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG"
  echo "Create it with at least: DIR=/path/to/images"
  exit 1
fi

source "$CONFIG"

: "${DIR:?DIR not set in $CONFIG}"

if [ ! -d "$DIR" ]; then
  echo "Directory not found: $DIR"
  exit 1
fi

for img in "$DIR"/*.jpeg "$DIR"/*.jpg; do
  [ -f "$img" ] || continue
  filename="$(basename "$img")"
  base="${filename%.*}"
  md="$DIR/${base}.md"

  [ -f "$md" ] && echo "SKIP $base (already exists)" && continue

  echo -n "$base ... "
  if claude -p --strict-mcp-config "Read the image and transcribe all text content exactly as it appears on the page. Output only the transcribed text, nothing else. Preserve paragraph breaks." "$img" > "$md" 2>/dev/null; then
    echo "DONE"
  else
    echo "FAIL"
  fi
done

echo "All done."
