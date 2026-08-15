#!/usr/bin/env bash
# Hybrid two-witness transcription: tesseract + Apple Vision OCR, word-level
# cross-check, Claude as arbiter only where the witnesses disagree.
#
#   ./transcribe-hybrid.sh            # all pages in $DIR (working-dir.conf)
#   ./transcribe-hybrid.sh 10         # single page
#   ./transcribe-hybrid.sh 5 15       # range (roman numerals work too)
#
# Per page:
#   1. tesseract and vision-ocr.swift each transcribe the image independently.
#   2. hybrid-merge.py compare aligns them. No disputes -> tesseract's version
#      is written as p.<N>.md (they agree token-wise; tesseract keeps the
#      nicer paragraph breaks).
#   3. Disputes -> claude gets the image, both transcripts and the dispute
#      list, and must copy agreed text verbatim while reading the disputed
#      spans off the page. hybrid-merge.py verify then checks that every
#      agreed token survived (>= MIN_COVERAGE); a drifting arbiter fails the
#      page loudly and no .md is written.
#
# Results land in $DIR/transcribe-status.tsv:
#   page  agreement  disputes  source(agreed|arbitrated)  coverage  result
# A failed arbitration (claude error or coverage below MIN_COVERAGE) stops
# the whole run immediately. The arbiter model/effort default to
# ARBITER_MODEL=claude-opus-4-8, ARBITER_EFFORT=high (env-overridable).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/working-dir.conf"
MIN_COVERAGE="${MIN_COVERAGE:-0.95}"
ARBITER_MODEL="${ARBITER_MODEL:-claude-opus-4-8}"
ARBITER_EFFORT="${ARBITER_EFFORT:-high}"

[ -f "$CONFIG" ] || { echo "Missing config: $CONFIG"; exit 1; }
source "$CONFIG"
DIR="${TRANSCRIBE_DIR:-$DIR}"   # env override, mainly for testing on another folder
: "${DIR:?DIR not set in $CONFIG}"
[ -d "$DIR" ] || { echo "Directory not found: $DIR"; exit 1; }

command -v tesseract >/dev/null || { echo "tesseract not installed"; exit 1; }
command -v swift >/dev/null || { echo "swift not available"; exit 1; }
command -v claude >/dev/null || { echo "claude CLI not available"; exit 1; }

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

is_roman() { [[ "${1,,}" =~ ^[ivxlcdm]+$ ]]; }

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

mapfile -t all_pages < <(collect_pages)
[ ${#all_pages[@]} -gt 0 ] || { echo "No p.*.jpeg/jpg files in $DIR"; exit 1; }

if [ $# -ge 2 ]; then
  from=$(sort_key "$1"); to=$(sort_key "$2"); filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p"); (( k >= from && k <= to )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
elif [ $# -eq 1 ]; then
  target=$(sort_key "$1"); filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p"); (( k == target )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
fi
[ ${#all_pages[@]} -gt 0 ] || { echo "No pages matched the given range."; exit 1; }

STATUS="$DIR/transcribe-status.tsv"
[ -f "$STATUS" ] || printf "page\tagreement\tdisputes\tsource\tcoverage\tresult\n" > "$STATUS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Pages: ${all_pages[*]}"
echo ""

for page in "${all_pages[@]}"; do
  img=""
  for ext in jpeg jpg; do
    [ -f "$DIR/p.${page}.${ext}" ] && img="$DIR/p.${page}.${ext}" && break
  done
  [ -z "$img" ] && echo "WARN p.$page: no image found" && continue

  md="$DIR/p.${page}.md"
  [ -f "$md" ] && echo "SKIP p.$page (already exists)" && continue

  echo -n "p.$page ... "

  A="$TMP/a.txt"; B="$TMP/b.txt"; REPORT="$TMP/report.txt"; FINAL="$TMP/final.txt"

  # Witness A: tesseract. Fail loudly — a broken witness breaks the run.
  tesseract "$img" "${A%.txt}" -l eng 2>/dev/null \
    || { echo "FAIL (tesseract)"; exit 1; }

  # Witness B: Apple Vision. A genuinely blank page is not an error: when
  # tesseract also sees no text there, an empty .md records the blank page
  # (same convention as the old tesseract-only pipeline). Only one witness
  # going silent while the other reads text stays a loud failure.
  if ! swift "$SCRIPT_DIR/vision-ocr.swift" "$img" > "$B" 2>"$TMP/vision-err.txt"; then
    if grep -q "zero text lines" "$TMP/vision-err.txt" && [ -z "$(tr -d '[:space:]' < "$A")" ]; then
      : > "$md"
      printf "%s\t-\t0\tblank\t-\tOK\n" "$page" >> "$STATUS"
      echo "OK (blank page)"
      continue
    fi
    cat "$TMP/vision-err.txt" >&2
    echo "FAIL (vision-ocr)"; exit 1
  fi

  set +e
  "$SCRIPT_DIR/hybrid-merge.py" compare "$A" "$B" > "$REPORT"
  cmp_exit=$?
  set -e
  read -r _ agreement _ disputes < <(head -1 "$REPORT")

  if [ "$cmp_exit" -eq 0 ]; then
    cp "$A" "$md"
    printf "%s\t%s\t%s\tagreed\t1.0000\tOK\n" "$page" "$agreement" "$disputes" >> "$STATUS"
    echo "OK (witnesses agree, ${agreement})"
    continue
  elif [ "$cmp_exit" -ne 3 ]; then
    echo "FAIL (compare exit $cmp_exit)"; cat "$REPORT"; exit 1
  fi

  # Arbitration: Claude reads the page image; agreed text is copied verbatim,
  # only the disputed spans are re-read from the image. The image lives
  # outside the repo (iCloud), hence --add-dir; the arbiter must prove it
  # actually saw the pixels or bail out with ARBITER-ERROR — never guess.
  prompt="You are the arbiter between two OCR transcripts of the same printed book page.
The page image is the file: $img
FIRST read that image file (Read tool). If you cannot open or see the image, output exactly 'ARBITER-ERROR: cannot read image' and nothing else. Never decide a dispute without having looked at the pixels.
Transcript A (tesseract) and transcript B (Apple Vision) agree on most of the text. Wherever they agree, that text is correct: copy it VERBATIM, do not rephrase, fix or normalize it.
They differ only at the disputed spans listed below. There — and only there — transcribe exactly what is printed on the page. The truth may match A, match B, or be something else.
Preserve paragraph breaks as blank lines. Keep line-end hyphenation exactly as printed on the page.
Output ONLY the final transcript, nothing else.

$(cat "$REPORT")

--- TRANSCRIPT A (tesseract) ---
$(cat "$A")

--- TRANSCRIPT B (Apple Vision) ---
$(cat "$B")"

  # Arbitration is not deterministic — a fluke attempt can drop agreed text
  # and fail verify while an identical re-run passes at full coverage. One
  # retry absorbs flukes; a page failing twice still stops the whole run.
  ok=""
  coverage="-"
  reason="claude"
  for attempt in 1 2; do
    if ! claude --model "$ARBITER_MODEL" --effort "$ARBITER_EFFORT" --add-dir "$DIR" -p "$prompt" > "$FINAL" 2>"$TMP/claude-err.txt" || [ ! -s "$FINAL" ]; then
      reason="claude"
      echo -n "(claude error, attempt $attempt) "
      continue
    fi
    if grep -q "ARBITER-ERROR" "$FINAL"; then
      # Structural: the arbiter cannot see the image. No retry will fix it.
      printf "%s\t%s\t%s\tarbitrated\t-\tFAILED(no-image)\n" "$page" "$agreement" "$disputes" >> "$STATUS"
      echo "FAILED (arbiter could not read the image) — stopping run"
      head -3 "$FINAL" >&2
      exit 1
    fi
    set +e
    coverage_line="$("$SCRIPT_DIR/hybrid-merge.py" verify "$FINAL" "$A" "$B" --min-coverage "$MIN_COVERAGE")"
    verify_exit=$?
    set -e
    coverage="$(echo "$coverage_line" | awk '{print $2}')"
    if [ "$verify_exit" -eq 0 ]; then
      ok=1
      break
    fi
    reason="coverage"
    echo -n "(coverage ${coverage} on attempt $attempt) "
  done

  if [ -n "$ok" ]; then
    cp "$FINAL" "$md"
    printf "%s\t%s\t%s\tarbitrated\t%s\tOK\n" "$page" "$agreement" "$disputes" "$coverage" >> "$STATUS"
    echo "OK (arbitrated ${disputes} disputes, coverage ${coverage})"
  else
    printf "%s\t%s\t%s\tarbitrated\t%s\tFAILED(%s)\n" "$page" "$agreement" "$disputes" "$coverage" "$reason" >> "$STATUS"
    [ -s "$FINAL" ] && cp "$FINAL" "$DIR/p.${page}.arbiter-failed.txt"
    [ -s "$TMP/claude-err.txt" ] && cat "$TMP/claude-err.txt" >&2
    echo "FAILED (${reason}, twice) — no .md written, stopping run"
    exit 1
  fi
done

echo ""
echo "All done."
