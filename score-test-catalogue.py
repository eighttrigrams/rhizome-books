#!/usr/bin/env -S uv run --quiet python
# /// script
# requires-python = ">=3.10"
# ///
"""
Score actual extracted bookquotes vs expectations.

For each example, compares MARK TYPE + PASSAGE only (not CONTEXT / WHY NOTABLE).

Metric per expected mark: best-match F1 of word overlap on PASSAGE text
(case-folded, punctuation-stripped, whitespace-normalised). The actual mark
is "claimed" by the best match and cannot be re-matched.

Reports per-example precision/recall/F1 and an overall average.
"""

from __future__ import annotations

import re
from pathlib import Path
from dataclasses import dataclass, field

ROOT = Path(__file__).parent
EXPECTATIONS = Path("/Users/daniel/Workspace/plurama.eighttrigrams/rhizome-books-test-catalogue/expectations.md")
OUT_DIR = ROOT / "test-catalogue-out"

WORD_RE = re.compile(r"[a-z0-9]+")
ELIPSIS_RE = re.compile(r"\[\s*…\s*\]|\[\s*\.\.\.\s*\]")


@dataclass
class Mark:
    mark_type: str = ""
    passage: str = ""


@dataclass
class Example:
    name: str
    subject: str
    marks: list[Mark] = field(default_factory=list)


def normalise(text: str) -> list[str]:
    text = ELIPSIS_RE.sub(" ", text)
    text = text.replace("**", " ").replace("[emphasis mine]", " ")
    return WORD_RE.findall(text.lower())


def f1(a: list[str], b: list[str]) -> float:
    if not a or not b:
        return 0.0
    common: dict[str, int] = {}
    a_count: dict[str, int] = {}
    for w in a:
        a_count[w] = a_count.get(w, 0) + 1
    b_count: dict[str, int] = {}
    for w in b:
        b_count[w] = b_count.get(w, 0) + 1
    overlap = 0
    for w, c in a_count.items():
        overlap += min(c, b_count.get(w, 0))
    if overlap == 0:
        return 0.0
    p = overlap / len(b)
    r = overlap / len(a)
    return 2 * p * r / (p + r)


def parse_expectations(path: Path) -> list[Example]:
    text = path.read_text()
    examples: list[Example] = []
    current: Example | None = None
    pending: dict[str, str] = {}

    def flush_pending():
        if current is None or not pending:
            return
        if pending.get("MARK TYPE") or pending.get("PASSAGE"):
            current.marks.append(
                Mark(
                    mark_type=pending.get("MARK TYPE", "").strip(),
                    passage=pending.get("PASSAGE", "").strip(),
                )
            )
        pending.clear()

    for raw in text.splitlines():
        line = raw.rstrip()
        m = re.match(r"^#\s*(example-\d+)\s*-\s*subject:\s*p\.(\S+)", line)
        if m:
            flush_pending()
            if current:
                examples.append(current)
            current = Example(name=m.group(1), subject=m.group(2))
            continue
        if line.startswith("MARK TYPE:"):
            flush_pending()
            pending["MARK TYPE"] = line.split(":", 1)[1].strip()
        elif line.startswith("PASSAGE:"):
            pending["PASSAGE"] = line.split(":", 1)[1].strip()
        elif line == "" and pending:
            flush_pending()
        else:
            # continuation of last field
            if pending.get("PASSAGE") is not None and "PASSAGE" in pending and line.strip():
                pending["PASSAGE"] = pending["PASSAGE"] + " " + line.strip()
    flush_pending()
    if current:
        examples.append(current)
    return examples


def parse_actual(path: Path) -> list[Mark]:
    if not path.exists():
        return []
    text = path.read_text()
    marks: list[Mark] = []
    pending: dict[str, str] = {}

    def flush():
        if pending.get("MARK TYPE") or pending.get("PASSAGE"):
            marks.append(
                Mark(
                    mark_type=pending.get("MARK TYPE", "").strip(),
                    passage=pending.get("PASSAGE", "").strip(),
                )
            )
        pending.clear()

    last_key: str | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("PAGE:"):
            flush()
            last_key = None
            continue
        if line.startswith("MARK TYPE:"):
            pending["MARK TYPE"] = line.split(":", 1)[1].strip()
            last_key = "MARK TYPE"
        elif line.startswith("PASSAGE:"):
            pending["PASSAGE"] = line.split(":", 1)[1].strip()
            last_key = "PASSAGE"
        elif line.startswith("CONTEXT:") or line.startswith("WHY NOTABLE:") or line == "-----":
            last_key = None
        elif line == "":
            continue
        else:
            if last_key in ("MARK TYPE", "PASSAGE") and line.strip():
                pending[last_key] = pending[last_key] + " " + line.strip()
    flush()
    return marks


def score_example(expected: Example, actual: list[Mark]) -> dict:
    exp_words = [normalise(m.passage) for m in expected.marks]
    act_words = [normalise(m.passage) for m in actual]

    used = [False] * len(actual)
    per_expected = []
    for i, ew in enumerate(exp_words):
        best = 0.0
        best_j = -1
        for j, aw in enumerate(act_words):
            if used[j]:
                continue
            s = f1(ew, aw)
            if s > best:
                best = s
                best_j = j
        if best_j >= 0 and best > 0:
            used[best_j] = True
        per_expected.append({
            "exp_passage": expected.marks[i].passage[:80],
            "match_score": round(best, 3),
            "matched_actual_idx": best_j,
        })

    recall = sum(p["match_score"] for p in per_expected) / max(len(per_expected), 1)
    n_expected = len(expected.marks)
    n_actual = len(actual)
    matched = sum(1 for u in used if u)
    extras = n_actual - matched
    precision = (sum(p["match_score"] for p in per_expected)) / max(n_actual, 1) if n_actual else 0.0

    f1_overall = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    count_penalty = 1.0 - min(1.0, abs(n_actual - n_expected) / max(n_expected, 1))

    return {
        "n_expected": n_expected,
        "n_actual": n_actual,
        "extras": extras,
        "recall": round(recall, 3),
        "precision": round(precision, 3),
        "f1": round(f1_overall, 3),
        "count_penalty": round(count_penalty, 3),
        "score": round(0.7 * f1_overall + 0.3 * count_penalty, 3),
        "per_expected": per_expected,
    }


def main() -> None:
    examples = parse_expectations(EXPECTATIONS)
    total_score = 0.0
    n = 0
    print(f"Scoring {len(examples)} example(s) from expectations.md\n")
    for ex in examples:
        actual_path = OUT_DIR / f"{ex.name}.md"
        actual = parse_actual(actual_path)
        result = score_example(ex, actual)
        print(f"=== {ex.name} (subject p.{ex.subject}) ===")
        print(
            f"  expected={result['n_expected']} actual={result['n_actual']} "
            f"extras={result['extras']} recall={result['recall']} "
            f"precision={result['precision']} f1={result['f1']} "
            f"count_penalty={result['count_penalty']} -> score={result['score']}"
        )
        for p in result["per_expected"]:
            print(f"    - exp: {p['exp_passage']!r:<82}  match={p['match_score']}  -> actual #{p['matched_actual_idx']}")
        print()
        total_score += result["score"]
        n += 1
    avg = total_score / max(n, 1)
    print(f"OVERALL average score: {round(avg, 3)}  (1.0 = perfect)")


if __name__ == "__main__":
    main()
