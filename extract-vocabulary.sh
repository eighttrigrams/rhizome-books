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

OUTPUT="${SCRIPT_DIR}/unknown-vocabulary.md"

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

PROMPT="$(cat "${SCRIPT_DIR}/prompts/extract-vocabulary.txt")"

for page in "${all_pages[@]}"; do
  img="$(find_image "$page")"
  if [ -z "$img" ]; then
    echo "WARN p.$page: no image"
    continue
  fi

  idx=$(idx_of "$page")
  args=()

  if (( idx > 0 )); then
    prev_page="${ordered[$((idx - 1))]}"
    prev_img="$(find_image "$prev_page")"
    if [ -n "$prev_img" ]; then
      args+=("$prev_img")
    fi
  fi

  args+=("$img")

  if (( idx < ${#ordered[@]} - 1 )); then
    next_page="${ordered[$((idx + 1))]}"
    next_img="$(find_image "$next_page")"
    if [ -n "$next_img" ]; then
      args+=("$next_img")
    fi
  fi

  n_imgs=${#args[@]}
  if (( n_imgs == 1 )); then
    position_hint="This is the only page image provided. It is the CURRENT PAGE (p.$page)."
  elif (( n_imgs == 2 )); then
    if (( idx == 0 )); then
      position_hint="Two images: first is the CURRENT PAGE (p.$page), second is the next page (context only)."
    else
      position_hint="Two images: first is the previous page (context only), second is the CURRENT PAGE (p.$page)."
    fi
  else
    position_hint="Three images: first is the previous page (context only), second is the CURRENT PAGE (p.$page), third is the next page (context only)."
  fi

  echo -n "p.$page ... "

  read_instructions=""
  for f in "${args[@]}"; do
    read_instructions="${read_instructions}
Read the image file: $f"
  done

  full_prompt="$PROMPT

$position_hint
$read_instructions

Only look for underlined words on the CURRENT PAGE (p.$page). The other pages are for sentence context only."

  result=$(echo "$full_prompt" | claude -p --model claude-opus-4-6 --effort max --add-dir "$DIR" --tools "Read" 2>/dev/null) || true

  if [ -z "$result" ] || [[ "$result" == "NONE" ]]; then
    echo "no underlined words"
    continue
  fi

  count=$(echo "$result" | grep -c "^WORD:" || true)
  echo "$count word(s) found"

  formatted=$(echo "$result" | awk '
    /^[[:space:]]*$/ { next }
    /^-+[[:space:]]*$/ { next }
    {
      if (out) {
        if (/^PAGE:/)      { print ""; print "---"; print "" }
        else if (/^WORD:/) print ""
      }
      print $0 "  "
      out = 1
    }
  ')

  if [ -s "$OUTPUT" ]; then
    printf '\n---\n\n' >> "$OUTPUT"
  fi

  printf '%s\n' "$formatted" >> "$OUTPUT"
done

echo ""
echo "Done. Results in: $OUTPUT"
