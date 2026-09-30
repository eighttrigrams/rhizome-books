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

# Ledger of settled pages, so a plain run picks up where the last one stopped.
# Lines: <dir>\t<page>\t<status>\t<detail>   status: ok | no-words | error
# Keyed by DIR as well as page: OUTPUT is shared across books, and page numbers
# repeat from book to book. Delete the file to start over.
STATUS="${OUTPUT%.md}.status.tsv"

BATCH=0   # 1 when run without page arguments (the next -n unsettled pages)

ledger_set() {
  local page="$1" st="$2" detail="${3:-}"
  if [ -f "$STATUS" ]; then
    awk -F'\t' -v d="$DIR" -v p="$page" '!($1==d && $2==p)' "$STATUS" > "$STATUS.tmp" \
      && mv "$STATUS.tmp" "$STATUS"
  fi
  printf '%s\t%s\t%s\t%s\n' "$DIR" "$page" "$st" "$detail" >> "$STATUS"
}

ledger_get() {
  local page="$1"
  [ -f "$STATUS" ] || return 0
  awk -F'\t' -v d="$DIR" -v p="$page" '$1==d && $2==p {v=$3} END{if(v)print v}' "$STATUS"
}

# Abort the whole run on a failed page, and record it in OUTPUT so the failure is
# visible in the result and not just in a terminal that may have scrolled away.
# Stopping (rather than skipping) matters here because the output is append-only:
# a skipped page would leave a hole, and running on past it would put the
# vocabulary list out of page order once the page is retried.
fail() {
  local page="$1" reason="$2" detail="${3:-}"
  echo "FAILED"
  ledger_set "$page" error "$reason"
  {
    echo ""
    echo "ERROR: extraction failed on p.${page} — ${reason}"
    if [ -n "$detail" ]; then
      echo "--- model stderr ---"
      echo "$detail"
      echo "--------------------"
    fi
    echo "Stopped. Pages after p.${page} were NOT processed."
    if [ "$BATCH" -eq 1 ]; then
      echo "Fix the cause, then run it again: it picks up at p.${page}."
    else
      echo "Fix the cause, then resume with:  $(basename "$0") ${page} <last-page>"
    fi
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

usage() {
  cat <<'EOF'
Extract hand-underlined vocabulary from scanned book pages.

Usage:
  ./extract-vocabulary.sh             process the next 10 pages not yet done,
                                      resuming from the ledger
  ./extract-vocabulary.sh -n 20       same, but up to 20 pages
  ./extract-vocabulary.sh 192         process a single page
  ./extract-vocabulary.sh 192 220     process a page range (inclusive)
  ./extract-vocabulary.sh --help      show this help

Results are appended to unknown-vocabulary.md. Finished pages are recorded
per working dir in unknown-vocabulary.status.tsv; a run without page
arguments skips them. Single-page and range runs always re-run the pages
they name (appending again) and are not limited by -n.
A failed page stops the run; the next run starts again at that page.
EOF
}

LIMIT=10
POSARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n)
      [ $# -ge 2 ] || { echo "-n needs a number"; exit 1; }
      LIMIT="$2"; shift ;;
    *) POSARGS+=("$1") ;;
  esac
  shift
done
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
  echo "Invalid -n value: '$LIMIT' (need a positive integer)"
  exit 1
fi

mapfile -t all_pages < <(collect_pages)

if [ ${#all_pages[@]} -eq 0 ]; then
  echo "No p.*.jpeg/jpg files in $DIR"
  exit 1
fi

if [ ${#POSARGS[@]} -ge 2 ]; then
  from=$(sort_key "${POSARGS[0]}")
  to=$(sort_key "${POSARGS[1]}")
  filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p")
    (( k >= from && k <= to )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
elif [ ${#POSARGS[@]} -eq 1 ]; then
  target=$(sort_key "${POSARGS[0]}")
  filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p")
    (( k == target )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
else
  # No page arguments: skip pages already settled, take the next LIMIT of the rest.
  BATCH=1
  unsettled=()
  for p in "${all_pages[@]}"; do
    case "$(ledger_get "$p")" in
      ok|no-words) ;;
      *) unsettled+=("$p") ;;
    esac
  done
  total_left=${#unsettled[@]}

  if [ "$total_left" -eq 0 ]; then
    echo "Nothing to do: every page in $DIR is already done."
    echo "(Delete $(basename "$STATUS") to start over.)"
    exit 0
  fi

  all_pages=("${unsettled[@]:0:$LIMIT}")

  if [ -f "$STATUS" ] \
     && awk -F'\t' -v d="$DIR" '$1==d && ($3=="ok" || $3=="no-words") {f=1} END{exit !f}' "$STATUS"; then
    echo "RESUMING — $total_left page(s) still to do; doing up to $LIMIT this run."
  else
    echo "STARTING FRESH — $total_left page(s) to do; doing up to $LIMIT this run."
  fi
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
    | claude -p --model claude-opus-4-8 --effort max --add-dir "$DIR" --tools "Read" \
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
    ledger_set "$page" no-words
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
  # Only after the words are safely in OUTPUT: a crash in between re-runs the
  # page (a duplicate) rather than skipping it (a hole).
  ledger_set "$page" ok "$count word(s)"
done

echo ""
echo "Done. Results in: $OUTPUT"
if [ "$BATCH" -eq 1 ]; then
  left=$(( total_left - ${#all_pages[@]} ))
  if (( left > 0 )); then
    echo "$left page(s) still to do — run again for the next batch."
  else
    echo "All pages in $DIR are done."
  fi
fi
