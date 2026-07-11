#!/usr/bin/env bash
# Extract marked passages from scanned book pages — resumable and repairable.
#
#   ./extract-bookquotes.sh                process the next 10 unsettled pages,
#                                          auto-resuming from the ledger if a
#                                          prior run left pages unfinished
#   ./extract-bookquotes.sh -n 25          same, but process up to 25 pages
#   ./extract-bookquotes.sh 192            process a single page
#   ./extract-bookquotes.sh 192 220        process a page range (inclusive)
#   ./extract-bookquotes.sh --cleanup      wipe ALL prior state (output, ledger,
#                                          per-page store, scratch), then re-run
#                                          from scratch
#   --cleanup may also prefix a narrower run, e.g. `--cleanup 192`.
#
# Default (no page args) auto-resumes: pages already ok/no-marks are skipped,
# and only the first N (default 10) still-unsettled pages are processed this run.
# Run it again to continue with the next batch.
#
# State, all derived from OUTPUT (so it is per-book when OUTPUT is overridden):
#   <output>.md          assembled result, rebuilt from the per-page store
#   <output>.pages/      one extracted block per page (p.<page>.md)
#   <output>.status.tsv  ledger lines: <page>\t<status>\t<detail>
#                        status: ok | no-marks | content-filter | outage | error
#
# No `set -e`: each page is handled explicitly and recorded in the ledger, so one
# bad page (missing image, content filter, model outage) never aborts the batch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/working-dir.conf"

# Allow DIR to be set in the environment (e.g. by run-test-catalogue.sh);
# otherwise fall back to working-dir.conf.
if [ -z "${DIR:-}" ]; then
  if [ ! -f "$CONFIG" ]; then
    echo "Missing config: $CONFIG (and DIR is not set in environment)"
    exit 1
  fi
  source "$CONFIG"
fi
: "${DIR:?DIR not set (env) and not found in $CONFIG}"

# OUTPUT and WORK are overridable from the environment so the test runner can give
# each example its own output file and scratch dir. State files are derived from
# OUTPUT so they always travel together.
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/extracted-bookquotes.md}"
WORK="${WORK:-${SCRIPT_DIR}/current-img}"
OUTPUT_BASE="${OUTPUT%.md}"
PAGES_DIR="${OUTPUT_BASE}.pages"
STATUS="${OUTPUT_BASE}.status.tsv"
MAX_RETRIES="${MAX_RETRIES:-3}"      # transient-outage retries per model call
CALL_TIMEOUT="${CALL_TIMEOUT:-600}"  # seconds before a hung model call is killed and retried
EXTRACT_EFFORT="${EXTRACT_EFFORT:-high}"  # one call now does detect+extract over many images, so use high effort

EXTRACT_PROMPT="$(cat "${SCRIPT_DIR}/prompts/extract-bookquotes.txt")"
MARGIN_PROMPT="$(cat "${SCRIPT_DIR}/prompts/margin-emphasis.txt")"

cleanup_work() { rm -rf "$WORK"; }

call_delay() { sleep $(( RANDOM % 5 + 1 )); }

# Call a model once, with content-filter detection and transient-outage retry.
# Sets globals CC_OUT (model text) and CC_STATUS (ok | content-filter | outage).
#
# Success/failure is decided from the CLI's JSON envelope (--output-format json),
# NOT by scanning the model's text. The old heuristic grepped stdout for error
# strings including \b5[0-9][0-9]\b (HTTP 5xx); on pages 500-599 the page number
# in the extracted text matched it, so every such page was falsely treated as a
# transient outage and retried to death. The envelope's `is_error` flag is the
# authoritative signal and carries no page-content ambiguity.
CC_OUT=""
CC_STATUS=""
claude_call() {
  local model="$1" input="$2" effort="${3:-$EXTRACT_EFFORT}"
  local attempt=0 delay=3 raw rc err is_error subtype result
  local infile="$WORK/.cc_in" outfile="$WORK/.cc_out" errfile="$WORK/.cc_err"
  while :; do
    attempt=$((attempt + 1))
    printf '%s' "$input" > "$infile"
    : > "$outfile"; : > "$errfile"
    # Run in the background under a watchdog so a HUNG call (model degraded but not
    # erroring) is killed and treated as a transient outage, instead of blocking
    # the whole batch forever.
    claude -p --model "$model" --effort "$effort" --output-format json --add-dir "$WORK" --tools "Read" \
      < "$infile" > "$outfile" 2>"$errfile" &
    local cpid=$! waited=0 timedout=0
    while kill -0 "$cpid" 2>/dev/null; do
      if [ "$waited" -ge "$CALL_TIMEOUT" ]; then
        kill "$cpid" 2>/dev/null; sleep 2; kill -9 "$cpid" 2>/dev/null
        timedout=1
        break
      fi
      sleep 3; waited=$((waited + 3))
    done
    wait "$cpid" 2>/dev/null; rc=$?
    raw="$(cat "$outfile" 2>/dev/null || true)"
    err="$(cat "$errfile" 2>/dev/null || true)"
    [ "$timedout" -eq 1 ] && { rc=124; err="${err} [timed out after ${CALL_TIMEOUT}s]"; }

    # Parse the JSON envelope. A well-formed envelope is authoritative; if stdout
    # does not parse as JSON the call itself failed (crash / timeout / non-JSON
    # error) and is handled as a failure below.
    if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      is_error="$(printf '%s' "$raw" | jq -r '.is_error // false')"
      subtype="$(printf '%s' "$raw" | jq -r '.subtype // ""')"
      result="$(printf '%s' "$raw" | jq -r '.result // ""')"
    else
      is_error="parse-failed"; subtype=""; result=""
    fi

    # Content filter is deterministic — retrying will not help, so flag and stop.
    # Only the envelope's error fields and stderr are scanned (never page text),
    # so an extracted passage that happens to mention "blocked" can't trip this.
    if printf '%s\n%s' "$subtype" "$err" | grep -qiE 'content filter|content_filter|output blocked'; then
      CC_OUT=""; CC_STATUS="content-filter"; return 0
    fi

    # A valid envelope reporting success is the only path to "ok". Page content
    # is never inspected for error markers.
    if [ "$is_error" = "false" ] && [ "$rc" -eq 0 ]; then
      CC_OUT="$result"; CC_STATUS="ok"; return 0
    fi

    # Everything else is a genuine call failure: unparseable output, is_error=true,
    # non-zero exit, or watchdog timeout. Retry with backoff, then give up.
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      sleep "$delay"; delay=$((delay * 2)); continue
    fi
    CC_OUT=""; CC_STATUS="outage"; return 0
  done
}

# ---- ledger -------------------------------------------------------------------
ledger_set() {
  local page="$1" st="$2" detail="${3:-}"
  mkdir -p "$(dirname "$STATUS")"
  if [ -f "$STATUS" ]; then
    awk -F'\t' -v p="$page" '$1!=p' "$STATUS" > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
  fi
  printf '%s\t%s\t%s\n' "$page" "$st" "$detail" >> "$STATUS"
}
ledger_get() {
  local page="$1"
  [ -f "$STATUS" ] || return 0
  awk -F'\t' -v p="$page" '$1==p{v=$2} END{if(v)print v}' "$STATUS"
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

# Rebuild OUTPUT from the per-page store (idempotent: re-running a page just
# overwrites its block, then OUTPUT is reassembled in page order).
assemble_output() {
  : > "$OUTPUT"
  local first=1 p f
  for p in "${ordered[@]}"; do
    f="$PAGES_DIR/p.${p}.md"
    [ -f "$f" ] || continue
    if [ "$first" -eq 0 ]; then printf '\n-----\n\n' >> "$OUTPUT"; fi
    cat "$f" >> "$OUTPUT"
    first=0
  done
}

# ---- arguments ----------------------------------------------------------------
usage() {
  cat <<'EOF'
Extract marked passages from scanned book pages — resumable and repairable.

Usage:
  ./extract-bookquotes.sh                process the next 10 unsettled pages,
                                         auto-resuming from the ledger
  ./extract-bookquotes.sh -n 25          same, but process up to 25 pages
  ./extract-bookquotes.sh 192            process a single page
  ./extract-bookquotes.sh 192 220        process a page range (inclusive)
  ./extract-bookquotes.sh --cleanup      wipe ALL prior state, then re-run
                                         from scratch (may prefix a page/range)
  ./extract-bookquotes.sh --help         show this help

Behaviour:
  With no page arguments the script AUTO-RESUMES. It skips pages already
  recorded as ok/no-marks in the ledger and processes at most N (default 10,
  set with -n) still-unsettled pages this run. Run it again to continue with
  the next batch. It prints a clear RESUMING / STARTING FRESH banner and the
  page count before it begins.

  Explicit single-page and range runs are NOT limited by -n.

State (derived from OUTPUT, so it is per-book when OUTPUT is overridden):
  <output>.md          assembled result, rebuilt from the per-page store
  <output>.pages/      one extracted block per page (p.<page>.md)
  <output>.status.tsv  ledger: <page>\t<status>\t<detail>
                       status: ok | no-marks | content-filter | outage | error
EOF
}

DO_CLEANUP=0
LIMIT=10
POSARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cleanup) DO_CLEANUP=1 ;;
    -n)        LIMIT="$2"; shift ;;
    *)         POSARGS+=("$1") ;;
  esac
  shift
done
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
  echo "Invalid -n value: '$LIMIT' (need a positive integer)"
  exit 1
fi

# Cleanup is page-independent — do it first so a fresh-from-scratch retry wipes all
# prior state, then the run proceeds normally (every page by default).
if [ "$DO_CLEANUP" -eq 1 ]; then
  echo "CLEANUP: wiping state for $(basename "$OUTPUT") — fresh start"
  rm -f "$OUTPUT"
  rm -rf "$PAGES_DIR"
  rm -f "$STATUS"
  rm -rf "$WORK"
  echo "  removed output, per-page store, ledger and scratch"
fi

mapfile -t ordered < <(collect_pages)
if [ ${#ordered[@]} -eq 0 ]; then
  echo "No p.*.jpeg/jpg files in $DIR"
  exit 1
fi

# ---- select pages -------------------------------------------------------------
all_pages=("${ordered[@]}")

if [ ${#POSARGS[@]} -ge 2 ]; then
  from=$(sort_key "${POSARGS[0]}"); to=$(sort_key "${POSARGS[1]}")
  sel=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p"); (( k >= from && k <= to )) && sel+=("$p")
  done
  all_pages=("${sel[@]}")
elif [ ${#POSARGS[@]} -eq 1 ]; then
  target=$(sort_key "${POSARGS[0]}")
  sel=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p"); (( k == target )) && sel+=("$p")
  done
  all_pages=("${sel[@]}")
else
  # Default: auto-resume. Skip pages already settled (ok/no-marks), then take at
  # most LIMIT of the still-unsettled ones. Running again continues the next batch.
  unsettled=()
  for p in "${all_pages[@]}"; do
    case "$(ledger_get "$p")" in
      ok|no-marks) ;;             # already settled — skip
      *)           unsettled+=("$p") ;; # failed / outage / content-filter / error / never attempted
    esac
  done
  total_left=${#unsettled[@]}
  all_pages=("${unsettled[@]:0:$LIMIT}")

  # "Something to resume" = the ledger already records at least one settled page.
  if [ -f "$STATUS" ] && awk -F'\t' '$2=="ok"||$2=="no-marks"{f=1} END{exit !f}' "$STATUS"; then
    echo "======================================================================"
    echo " RESUMING — a previous run left pages unfinished."
    echo " $total_left page(s) still unsettled; processing up to $LIMIT this run."
    echo "======================================================================"
  else
    echo "======================================================================"
    echo " STARTING FRESH — no prior progress found."
    echo " $total_left page(s) to process; doing up to $LIMIT this run."
    echo "======================================================================"
  fi
fi

if [ ${#all_pages[@]} -eq 0 ]; then
  echo "No pages to process."
  [ -d "$PAGES_DIR" ] && assemble_output
  exit 0
fi

echo "Pages to scan (${#all_pages[@]}): ${all_pages[*]}"
echo "Output: $OUTPUT"
echo ""

mkdir -p "$PAGES_DIR"

idx_of() {
  local target="$1"
  for i in "${!ordered[@]}"; do
    if [[ "${ordered[$i]}" == "$target" ]]; then
      echo "$i"; return
    fi
  done
  echo "-1"
}

for page in "${all_pages[@]}"; do
  src_img="$(find_image "$page")"
  if [ -z "$src_img" ]; then
    echo "WARN p.$page: no image"
    ledger_set "$page" error "no image file"
    continue
  fi

  cleanup_work
  mkdir -p "$WORK"

  ext="${src_img##*.}"
  full="$WORK/p.${page}.${ext}"
  tl="$WORK/p.${page}.tl.${ext}"
  tr="$WORK/p.${page}.tr.${ext}"
  bl="$WORK/p.${page}.bl.${ext}"
  br="$WORK/p.${page}.br.${ext}"
  lmg="$WORK/p.${page}.lmg.${ext}"
  rmg="$WORK/p.${page}.rmg.${ext}"

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

  # Focused margin-emphasis pass: tall upscaled strips of the left/right margins,
  # whose only job is to spot marks that SINGLE OUT a passage (bold hook, arrow,
  # "!", star, comment). A dedicated, focused call perceives these far more
  # reliably than the overloaded detect+extract call, which keeps mistaking a
  # bold hand-drawn "!" for a plain structural line.
  SMW=$((W*22/100))
  magick "$full" -crop "${SMW}x${H}+0+0" +repage -resize 220% "$lmg"
  magick "$full" -crop "${SMW}x${H}+$((W-SMW))+0" +repage -resize 220% "$rmg"
  margin_input="$MARGIN_PROMPT

Read the image file: $lmg   (LEFT margin strip, upscaled)
Read the image file: $rmg   (RIGHT margin strip, upscaled)
"
  call_delay
  claude_call "claude-opus-4-8" "$margin_input" "medium"
  margin_notes="$CC_OUT"
  [ "$CC_STATUS" = "ok" ] || margin_notes=""   # margin pass errored/outaged -> proceed without it

  echo -n "p.$page detect+extract (full + 4 quadrants + margin pass, ${EXTRACT_EFFORT} effort) ... "

  extract_input="$EXTRACT_PROMPT

PAGE LABEL: $page

MARGIN-EMPHASIS PASS (a separate focused scan of the margins; treat each
SINGLED OUT passage below as carrying an emphatic margin mark -> set
IMPORTANT: yes on the extracted passage it matches):
---
${margin_notes:-NONE}
---

Images available — Read every one:
Read the image file: $full   (CURRENT page p.${page}, FULL — authoritative for layout and how far each mark extends)
Read the image file: $tl   (current page TOP-LEFT quadrant, zoomed — use to confirm faint underlines and small margin marks)
Read the image file: $tr   (current page TOP-RIGHT quadrant, zoomed)
Read the image file: $bl   (current page BOTTOM-LEFT quadrant, zoomed)
Read the image file: $br   (current page BOTTOM-RIGHT quadrant, zoomed)"

  if [ -n "$prev_full" ]; then
    extract_input="${extract_input}
Read the image file: $prev_full   (PREVIOUS page p.${prev_page} — context only, for completing overflow passages)"
  fi
  if [ -n "$next_full" ]; then
    extract_input="${extract_input}
Read the image file: $next_full   (NEXT page p.${next_page} — context only, for completing overflow passages)"
  fi

  call_delay
  claude_call "claude-opus-4-8" "$extract_input"
  extract_result="$CC_OUT"

  if [ "$CC_STATUS" = "content-filter" ]; then
    echo "BLOCKED (content filter)"
    ledger_set "$page" content-filter "extract blocked"
    assemble_output
    continue
  fi
  if [ "$CC_STATUS" = "outage" ]; then
    echo "OUTAGE (extract unavailable; retry with: resume)"
    ledger_set "$page" outage "extract unavailable"
    assemble_output
    continue
  fi

  if [ -z "$extract_result" ] || [[ "$extract_result" == "NONE" ]]; then
    echo "no passages extracted"
    rm -f "$PAGES_DIR/p.${page}.md"
    ledger_set "$page" no-marks "extract NONE"
    assemble_output
    continue
  fi

  count=$(echo "$extract_result" | grep -c "^PASSAGE:" || true)
  echo "$count passage(s)"
  printf '%s\n' "$extract_result" > "$PAGES_DIR/p.${page}.md"
  ledger_set "$page" ok "$count passages"
  assemble_output
done

echo ""
echo "Done. Results in: $OUTPUT"
if [ -f "$STATUS" ]; then
  echo "Ledger ($(basename "$STATUS")):"
  awk -F'\t' '{c[$2]++} END{for(k in c) printf "  %-15s %d\n", k, c[k]}' "$STATUS"
  failed=$(awk -F'\t' '$2!="ok" && $2!="no-marks"{n++} END{print n+0}' "$STATUS")
  if [ "$failed" -gt 0 ]; then
    echo "  -> $failed page(s) need repair; just re-run:  ./extract-bookquotes.sh"
  fi
fi
