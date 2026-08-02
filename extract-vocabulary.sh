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

# Abort the whole run on a failed page, and record it in OUTPUT so the failure is
# visible in the result and not just in a terminal that may have scrolled away.
# Stopping (rather than skipping) matters here because the output is append-only
# with no ledger: a skipped page would leave a silent hole in the vocabulary list.
fail() {
  local page="$1" reason="$2" detail="${3:-}"
  echo "FAILED"
  {
    echo ""
    echo "ERROR: extraction failed on p.${page} — ${reason}"
    if [ -n "$detail" ]; then
      echo "--- model stderr ---"
      echo "$detail"
      echo "--------------------"
    fi
    echo "Stopped. Pages after p.${page} were NOT processed."
    echo "Fix the cause, then resume with:  $(basename "$0") ${page} <last-page>"
  } >&2

  if [ -s "$OUTPUT" ]; then
    printf '\n---\n\n' >> "$OUTPUT"
  fi
  printf 'EXTRACTION FAILED at p.%s — %s\nRun stopped here; no pages after p.%s were processed.\n' \
    "$page" "$reason" "$page" >> "$OUTPUT"

  exit 1
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

PROMPT="$(cat "${SCRIPT_DIR}/prompts/extract-vocabulary.txt")"

for page in "${all_pages[@]}"; do
  img="$(find_image "$page")"
  if [ -z "$img" ]; then
    echo -n "p.$page ... "
    fail "$page" "no image file found"
  fi

  # Neighbouring pages travel with the current one so a sentence that crosses a
  # page boundary can still be quoted in full. They are context only — never
  # scanned for underlines.
  idx=$(idx_of "$page")
  prev_page=""; prev_img=""
  next_page=""; next_img=""

  if (( idx > 0 )); then
    prev_page="${ordered[$((idx - 1))]}"
    prev_img="$(find_image "$prev_page")"
  fi

  if (( idx >= 0 && idx < ${#ordered[@]} - 1 )); then
    next_page="${ordered[$((idx + 1))]}"
    next_img="$(find_image "$next_page")"
  fi

  echo -n "p.$page ... "

  # Every image line carries its own label. The previous version described the
  # images by argument order instead ("first is the previous page, second is the
  # CURRENT PAGE"), which mislabels the current page whenever a neighbour image is
  # absent — and then underlines get attributed to the wrong page.
  read_instructions="Read the image file: $img   (CURRENT page p.${page} — the ONLY page to scan for underlined words)"
  if [ -n "$prev_img" ]; then
    read_instructions="${read_instructions}
Read the image file: $prev_img   (PREVIOUS page p.${prev_page} — context only, for a sentence that starts there)"
  fi
  if [ -n "$next_img" ]; then
    read_instructions="${read_instructions}
Read the image file: $next_img   (NEXT page p.${next_page} — context only, for a sentence that finishes there)"
  fi

  full_prompt="$PROMPT

PAGE LABEL: $page

Images available — Read the CURRENT page; read a neighbour only if a sentence
needs it to be complete:
$read_instructions"

  # stderr is captured rather than discarded, so a failure can say WHY it failed.
  err_file="$(mktemp)"
  rc=0
  result=$(printf '%s' "$full_prompt" \
    | claude -p --model claude-opus-4-6 --effort max --add-dir "$DIR" --tools "Read" \
        2>"$err_file") || rc=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"

  if [ "$rc" -ne 0 ]; then
    fail "$page" "the model call exited with status $rc" "$err"
  fi

  # A successful call always emits something — at minimum the literal NONE. Empty
  # output therefore means the call did not really succeed, and must NOT be read as
  # "no underlined words": that conflation is what let a broken call pass silently
  # as a clean page.
  if [ -z "$result" ]; then
    fail "$page" "the model returned empty output" "$err"
  fi

  if [[ "$result" == "NONE" ]]; then
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
        if (/^PAGE:/)                    { print ""; print "---" }
        else if (/^WORD:/)               print ""
        else if (/^GERMAN TRANSLATION:/) print ""
      }
      print $0 "  "
      out = 1
    }
  ')

  if [ -s "$OUTPUT" ]; then
    printf '\n---\n' >> "$OUTPUT"
  fi

  printf '%s\n' "$formatted" >> "$OUTPUT"
done

echo ""
echo "Done. Results in: $OUTPUT"
