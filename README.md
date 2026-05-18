# Rhizome Ingest

## Ingest

### Page numbering

An ingest starts with a folder of photos of individual pages, best 
taken with the `vflat` app.

Use this prompt

```
Read every page of /absolute/path/to/your/working/directory and     
  name it according to its page number. i.e. p.1.jpg for page one        
  (preserve file ending as is). 
```  

I have tested this for roughly 30 pages.

### Transcription

Use `./transcribe-all.sh` to transcribe the files. Set the working dir
in `transcribe.conf`. It uses `tesseract` OCR (installed via `homebrew`).
It creates sidecar files for each of the files.

### Bookquotes

Extacts underlined pages.

```
./extract-bookquotes.sh # all pages
./extract-bookquotes.sh 10 # single page
./extract-bookquotes.sh 5 15 # range
```

Roman numerals work as well here.

### New vocabulary

Extracts new vocabulary.

```
./extract-vocabulary.sh
```

Supports the same range arguments as `extract-bookquotes.sh`.

## Development

Use

```bash
reset-dev-db.sh
```

## Prompt tuning (bookquotes)

Examples live in `../rhizome-books-test-catalogue/` (one folder per
`example-NNN`, plus an `expectations.md` listing the expected
`MARK TYPE` / `PASSAGE` per subject page).

Loop:

1. `./run-test-catalogue.sh` — runs `extract-bookquotes.sh` against
   every example discovered from `expectations.md` headings. Outputs
   go to `test-catalogue-out/<example>.md`.
2. `./score-test-catalogue.py` — compares `MARK TYPE` + `PASSAGE`
   against `expectations.md` (word-overlap F1 + count penalty) and
   prints a per-example score and an overall average.
3. Tweak `prompts/extract-bookquotes.txt`, repeat. Goal: overall
   score → 1.0.
