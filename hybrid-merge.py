#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# ///
"""
Word-level cross-check between two OCR witnesses of the same page, and
verification of an arbitrated transcript. Part of transcribe-hybrid.sh.

Tokens are canonicalized before comparison so that purely typographic
differences never count as disputes: NFKC-normalized (ligatures, ellipses),
curly quotes folded to straight ones, every dash variant folded to "-",
case-folded, tokens split at dashes (so "state—life" aligns with "state — life"),
and punctuation-only fragments dropped. Where the canonical streams agree,
witness A's original rendering (tesseract keeps the printed typography:
curly quotes, em dashes) is what stands. Only content-level differences
become disputes for the arbiter.

Commands:

  compare A.txt B.txt
      Aligns the two transcripts canonically. Prints a report to stdout:
      first line "AGREEMENT <ratio> DISPUTES <n>", then one block per
      disputed span:
          == dispute <i> (context: ...preceding words of A...)
          A: <what witness A reads, original rendering>
          B: <what witness B reads, original rendering>
      Exit 0 when there are no disputes (the page needs no arbiter, use A),
      exit 3 when there are (the report is the arbiter's work order).

  verify FINAL.txt A.txt B.txt [--min-coverage 0.95]
      Checks the arbitrated transcript against the agreed core of A and B:
      every canonical token the witnesses agree on must reappear in FINAL.
      Ordered coverage is checked first; when it falls short, order-free
      (bag) coverage decides — on diagram/figure pages the witnesses read
      the layout in one interleaving and the arbiter may legitimately
      reorder it, but tokens going missing or changing is drift either
      way. Prints "COVERAGE <effective> (ordered <o>, bag <b>, ...)".
      Exit 0 when either ratio >= min, else exit 4 — the page must fail
      loudly.
"""
import argparse
import difflib
import sys
import unicodedata
from collections import Counter
from pathlib import Path

QUOTE_FOLD = str.maketrans({
    "“": '"', "”": '"', "„": '"', "«": '"', "»": '"',
    "‘": "'", "’": "'", "‚": "'",
})
DASHES = "‐‑‒–—―−"
PUNCT_ONLY = set('"\'-' + DASHES)


def raw_tokens(path):
    return Path(path).read_text(encoding="utf-8", errors="replace").split()


def canonicalize(tokens):
    """Return (canon, origin): the canonical token stream and, per canonical
    token, the index of the original token it came from."""
    canon, origin = [], []
    for idx, tok in enumerate(tokens):
        t = unicodedata.normalize("NFKC", tok).translate(QUOTE_FOLD)
        for d in DASHES:
            t = t.replace(d, "-")
        t = t.casefold()
        for part in t.split("-"):
            if part and not set(part) <= PUNCT_ONLY:
                canon.append(part)
                origin.append(idx)
    return canon, origin


def span_text(tokens, origin, c1, c2, canon_len):
    """Original-rendering text behind canonical span [c1, c2)."""
    if c1 == c2:
        return ""
    lo = origin[c1]
    hi = origin[c2 - 1] if c2 - 1 < canon_len else origin[-1]
    return " ".join(tokens[lo : hi + 1])


def cmd_compare(args):
    a = raw_tokens(args.a)
    b = raw_tokens(args.b)
    if not a or not b:
        sys.exit(f"empty witness transcript: {'A' if not a else 'B'}")
    ca, oa = canonicalize(a)
    cb, ob = canonicalize(b)
    sm = difflib.SequenceMatcher(a=ca, b=cb, autojunk=False)
    opcodes = [op for op in sm.get_opcodes() if op[0] != "equal"]
    print(f"AGREEMENT {sm.ratio():.4f} DISPUTES {len(opcodes)}")
    for i, (tag, i1, i2, j1, j2) in enumerate(opcodes, 1):
        ctx_lo = oa[max(0, i1 - 6)] if ca else 0
        ctx_hi = oa[i1 - 1] + 1 if i1 > 0 else 0
        ctx = " ".join(a[ctx_lo:ctx_hi])
        print(f"== dispute {i} (context: …{ctx})")
        print(f"A: {span_text(a, oa, i1, i2, len(ca)) or '(nothing)'}")
        print(f"B: {span_text(b, ob, j1, j2, len(cb)) or '(nothing)'}")
    sys.exit(0 if not opcodes else 3)


def cmd_verify(args):
    ca, _ = canonicalize(raw_tokens(args.a))
    cb, _ = canonicalize(raw_tokens(args.b))
    cf, _ = canonicalize(raw_tokens(args.final))
    sm = difflib.SequenceMatcher(a=ca, b=cb, autojunk=False)
    core = []
    for block in sm.get_matching_blocks():
        core.extend(ca[block.a : block.a + block.size])
    if not core:
        sys.exit("witnesses share no agreed tokens — nothing to verify against")
    smf = difflib.SequenceMatcher(a=core, b=cf, autojunk=False)
    ordered = sum(bl.size for bl in smf.get_matching_blocks()) / len(core)
    bag_kept = sum((Counter(core) & Counter(cf)).values())
    bag = bag_kept / len(core)
    effective = ordered if ordered >= args.min_coverage else bag
    print(f"COVERAGE {effective:.4f} (ordered {ordered:.4f}, bag {bag:.4f}, core {len(core)})")
    sys.exit(0 if effective >= args.min_coverage else 4)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("a")
    c.add_argument("b")
    c.set_defaults(fn=cmd_compare)
    v = sub.add_parser("verify")
    v.add_argument("final")
    v.add_argument("a")
    v.add_argument("b")
    v.add_argument("--min-coverage", type=float, default=0.95)
    v.set_defaults(fn=cmd_verify)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
