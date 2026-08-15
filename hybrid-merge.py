#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# ///
"""
Word-level cross-check between two OCR witnesses of the same page, and
verification of an arbitrated transcript. Part of transcribe-hybrid.sh.

Commands:

  compare A.txt B.txt
      Aligns the two transcripts token-wise. Prints a report to stdout:
      first line "AGREEMENT <ratio> DISPUTES <n>", then one block per
      disputed span:
          == dispute <i> (context: ...preceding agreed words...)
          A: <what witness A reads>
          B: <what witness B reads>
      Exit 0 when there are no disputes (the page needs no arbiter),
      exit 3 when there are (the report is the arbiter's work order).

  verify FINAL.txt A.txt B.txt [--min-coverage 0.95]
      Checks the arbitrated transcript against the agreed core of A and B:
      every token the witnesses agree on must reappear in FINAL, in order.
      Prints "COVERAGE <ratio>". Exit 0 when coverage >= min, else exit 4 —
      the arbiter drifted and the page must fail loudly.

Tokens are compared case-sensitively, whitespace-normalized. The agreed core
is the longest common subsequence of the two witness token streams.
"""
import argparse
import difflib
import sys
from pathlib import Path


def tokens(path):
    return Path(path).read_text(encoding="utf-8", errors="replace").split()


def agreed_core(a, b):
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    core = []
    for block in sm.get_matching_blocks():
        core.extend(a[block.a : block.a + block.size])
    return core, sm


def cmd_compare(args):
    a = tokens(args.a)
    b = tokens(args.b)
    if not a or not b:
        sys.exit(f"empty witness transcript: {'A' if not a else 'B'}")
    core, sm = agreed_core(a, b)
    opcodes = [op for op in sm.get_opcodes() if op[0] != "equal"]
    ratio = sm.ratio()
    print(f"AGREEMENT {ratio:.4f} DISPUTES {len(opcodes)}")
    for i, (tag, i1, i2, j1, j2) in enumerate(opcodes, 1):
        ctx = " ".join(a[max(0, i1 - 6) : i1])
        print(f"== dispute {i} (context: …{ctx})")
        print(f"A: {' '.join(a[i1:i2]) or '(nothing)'}")
        print(f"B: {' '.join(b[j1:j2]) or '(nothing)'}")
    sys.exit(0 if not opcodes else 3)


def cmd_verify(args):
    final = tokens(args.final)
    a = tokens(args.a)
    b = tokens(args.b)
    core, _ = agreed_core(a, b)
    if not core:
        sys.exit("witnesses share no agreed tokens — nothing to verify against")
    sm = difflib.SequenceMatcher(a=core, b=final, autojunk=False)
    kept = sum(bl.size for bl in sm.get_matching_blocks())
    coverage = kept / len(core)
    print(f"COVERAGE {coverage:.4f} ({kept}/{len(core)} agreed tokens kept)")
    sys.exit(0 if coverage >= args.min_coverage else 4)


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
