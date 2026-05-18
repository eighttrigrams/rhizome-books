#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/working-dir.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG"
  exit 1
fi

source "$CONFIG"
: "${DIR:?DIR not set in $CONFIG}"

OUTPUT="${SCRIPT_DIR}/extracted-bookquotes.md"
WORK="${SCRIPT_DIR}/current-img"

OBSERVE_PROMPT="$(cat "${SCRIPT_DIR}/prompts/observe-marks.txt")"
EXTRACT_PROMPT="$(cat "${SCRIPT_DIR}/prompts/extract-bookquotes.txt")"

cleanup() { rm -rf "$WORK"; }

call_delay() {
  sleep $(( RANDOM % 5 + 1 ))
}

roman_to_int() {
  local input="${1,,}"
  local result=0 prev=0 val=0
  local i len=${#input}
  for (( i=len-1; i>=0; i-- )); do
    case "${input:$i:1}" in
      i) val=1 ;; v) val=5 ;; x) val=10 ;; l) val=50 ;;
      c) val=100 ;; d) val=500 ;; m) val=1000 ;;
      *) return 1 ;;
    esac
    (( val < prev )) && result=$((result - val)) || result=$((result + val))
    prev=$val
  done
  echo "$result"
}

is_roman() {
  [[ "${1,,}" =~ ^[ivxlcdm]+$ ]]
}

sort_key() {
  if is_roman "$1"; then
    echo $(( $(roman_to_int "$1") - 10000 ))
  else
    echo "$1"
  fi
}

collect_pages() {
  for img in "$DIR"/p.*.jpeg "$DIR"/p.*.jpg; do
    [ -f "$img" ] || continue
    local f
    f="$(basename "$img")"
    f="${f#p.}"
    f="${f%.*}"
    echo "$(sort_key "$f") $f"
  done | sort -n -k1 | awk '{print $2}'
}

find_image() {
  local page="$1"
  for ext in jpeg jpg; do
    if [ -f "$DIR/p.${page}.${ext}" ]; then
      echo "$DIR/p.${page}.${ext}"
      return
    fi
  done
}

mapfile -t all_pages < <(collect_pages)

if [ ${#all_pages[@]} -eq 0 ]; then
  echo "No p.*.jpeg/jpg files in $DIR"
  exit 1
fi

if [ $# -ge 2 ]; then
  from=$(sort_key "$1")
  to=$(sort_key "$2")
  filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p")
    (( k >= from && k <= to )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
elif [ $# -eq 1 ]; then
  target=$(sort_key "$1")
  filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p")
    (( k == target )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
fi

if [ ${#all_pages[@]} -eq 0 ]; then
  echo "No pages matched."
  exit 1
fi

echo "Pages to scan: ${all_pages[*]}"
echo "Output: $OUTPUT"
echo ""

mapfile -t ordered < <(collect_pages)

idx_of() {
  local target="$1"
  for i in "${!ordered[@]}"; do
    if [[ "${ordered[$i]}" == "$target" ]]; then
      echo "$i"
      return
    fi
  done
  echo "-1"
}

observe_one() {
  local label="$1"; local img="$2"; local hint="$3"
  local input="$OBSERVE_PROMPT

You are looking at: $hint

Read the image file: $img
"
  echo "$input" | claude -p --model claude-opus-4-7 --effort low --add-dir "$WORK" --tools "Read" 2>/dev/null || true
}

for page in "${all_pages[@]}"; do
  src_img="$(find_image "$page")"
  if [ -z "$src_img" ]; then
    echo "WARN p.$page: no image"
    continue
  fi

  cleanup
  mkdir -p "$WORK"

  ext="${src_img##*.}"
  full="$WORK/p.${page}.${ext}"
  tl="$WORK/p.${page}.tl.${ext}"
  tr="$WORK/p.${page}.tr.${ext}"
  bl="$WORK/p.${page}.bl.${ext}"
  br="$WORK/p.${page}.br.${ext}"
  observation="$WORK/p.${page}.observation.txt"

  cp "$src_img" "$full"

  idx=$(idx_of "$page")
  prev_full=""
  next_full=""
  if (( idx > 0 )); then
    prev_page="${ordered[$((idx - 1))]}"
    prev_src="$(find_image "$prev_page")"
    if [ -n "$prev_src" ]; then
      prev_ext="${prev_src##*.}"
      prev_full="$WORK/p.${prev_page}.${prev_ext}"
      cp "$prev_src" "$prev_full"
    fi
  fi
  if (( idx < ${#ordered[@]} - 1 )); then
    next_page="${ordered[$((idx + 1))]}"
    next_src="$(find_image "$next_page")"
    if [ -n "$next_src" ]; then
      next_ext="${next_src##*.}"
      next_full="$WORK/p.${next_page}.${next_ext}"
      cp "$next_src" "$next_full"
    fi
  fi

  W=$(magick identify -format "%w" "$full")
  H=$(magick identify -format "%h" "$full")
  HALF_W=$((W/2 + 100))
  HALF_H=$((H/2 + 100))
  magick "$full" -crop "${HALF_W}x${HALF_H}+0+0" +repage "$tl"
  magick "$full" -crop "${HALF_W}x${HALF_H}+$((W-HALF_W))+0" +repage "$tr"
  magick "$full" -crop "${HALF_W}x${HALF_H}+0+$((H-HALF_H))" +repage "$bl"
  magick "$full" -crop "${HALF_W}x${HALF_H}+$((W-HALF_W))+$((H-HALF_H))" +repage "$br"

  echo -n "p.$page observe (4 quadrants) ... "

  : > "$observation"

  variant_specs=(
    "TL|the TOP-LEFT quadrant of the page. Scan its left margin and body text for marks."
    "TR|the TOP-RIGHT quadrant of the page. Scan its right margin and body text for marks."
    "BL|the BOTTOM-LEFT quadrant of the page. Scan its left margin and body text for marks. Vertical positions in this image correspond to the LOWER half of the original page."
    "BR|the BOTTOM-RIGHT quadrant of the page. Scan its right margin and body text for marks. Vertical positions in this image correspond to the LOWER half of the original page."
  )

  total_marks=0
  for spec in "${variant_specs[@]}"; do
    name="${spec%%|*}"
    hint="${spec#*|}"
    case "$name" in
      TL) img="$tl" ;;
      TR) img="$tr" ;;
      BL) img="$bl" ;;
      BR) img="$br" ;;
    esac

    call_delay
    result=$(observe_one "$name" "$img" "$hint")

    {
      echo "===== VARIANT: $name ====="
      if [ -z "$result" ]; then
        echo "(no result)"
      else
        echo "$result"
      fi
      echo ""
    } >> "$observation"

    if [ -n "$result" ] && [[ "$result" != "NO MARKS" ]]; then
      n=$(echo "$result" | grep -c "^MARK:" || true)
      total_marks=$((total_marks + n))
    fi
  done

  if (( total_marks == 0 )); then
    echo "no marks"
    continue
  fi

  echo -n "${total_marks} raw mark(s); extract ... "

  extract_input="$EXTRACT_PROMPT

PAGE LABEL: $page

COMBINED OBSERVATION REPORT (from 4 quadrant passes — DEDUPLICATE marks that appear in adjacent quadrants):
---
$(cat "$observation")
---

Images available:
"

  if [ -n "$prev_full" ]; then
    extract_input="${extract_input}
Read the image file: $prev_full   (PREVIOUS page p.${prev_page} — context only, for completing overflow passages)"
  fi
  extract_input="${extract_input}
Read the image file: $full   (CURRENT page p.${page} — focus marks here)"
  if [ -n "$next_full" ]; then
    extract_input="${extract_input}
Read the image file: $next_full   (NEXT page p.${next_page} — context only, for completing overflow passages)"
  fi

  call_delay
  # Bumped to medium so the extract pass actually re-verifies mark extents against the page image
  # instead of trusting the (often truncated) observation report.
  extract_result=$(echo "$extract_input" | claude -p --model claude-opus-4-7 --effort medium --add-dir "$WORK" --tools "Read" 2>/dev/null) || true

  if [ -z "$extract_result" ] || [[ "$extract_result" == "NONE" ]]; then
    echo "no passages extracted"
    continue
  fi

  count=$(echo "$extract_result" | grep -c "^PASSAGE:" || true)
  echo "$count passage(s)"

  if [ -f "$OUTPUT" ]; then
    echo "" >> "$OUTPUT"
    echo "-----" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
  fi

  echo "$extract_result" >> "$OUTPUT"
done

echo ""
echo "Done. Results in: $OUTPUT"
