#!/usr/bin/env python3
"""
Generate "Did you know?" snippets for KeebLock codewords.

Reads each entry's `facts` array from `KeebLock/Resources/codeword_data.json`,
sentence-splits the paragraphs, scores each sentence by interestingness
heuristics, and writes the top N picks back as a `did_you_know` array on
the same entry. Idempotent — safe to re-run; preserves all other fields.

The heuristic favours sentences that:
  - contain numbers (years, heights, temperatures, percentages)
  - contain superlatives (only, first, largest, oldest …)
  - mention etymology / discovery (named, called, derived from, discovered)
and penalises sentences starting with a pronoun ("It …", "They …") because
those lose meaning without their preceding context.

The shipped corpus is agent-authored, not this script's output (see
CLAUDE.md > Data pipeline) — a bare run overwrites it with thinner heuristic
snippets, so it requires --force or --keep as an explicit confirmation.

Usage (from repo root):
    python3 scripts/build_dyk.py --force        # rebuild DYK for every entry
    python3 scripts/build_dyk.py --force --only foo,bar
    python3 scripts/build_dyk.py --keep         # only fill entries missing did_you_know
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "KeebLock" / "Resources" / "codeword_data.json"

# Match the shipped agent-authored corpus budget (6 snippets/word, ~410 chars).
DYK_COUNT = 6     # snippets per codeword
MIN_LEN = 60      # min sentence length, chars (skip stubs)
MAX_LEN = 410     # max sentence length, chars (HUD-readable)

SUPERLATIVES = re.compile(
    r"\b(only|first|last|largest|smallest|highest|lowest|tallest|"
    r"shortest|oldest|newest|deepest|widest|longest|fastest|slowest|"
    r"hottest|coldest|most|least|earliest|latest|biggest|heaviest)\b",
    re.I,
)
NUMBERS = re.compile(r"\b\d+(?:[.,]\d+)?\b")
NAMED = re.compile(
    r"\b(named|called|known as|derives from|comes from|originated|"
    r"discovered|invented|founded|established|recorded)\b",
    re.I,
)
PRONOUN_START = re.compile(r"^(it|they|this|these|those|he|she|its|their)\b", re.I)

# A broken citation snippet that survived the HTML parser, e.g.
# "(2003) suggest that warm spring is not useful…" — these read as
# nonsense without their preceding author name. Drop outright.
BROKEN_REF = re.compile(r"^\(\d{2,4}[a-z]?\)\s+\w+", re.I)

# Wikipedia lead-style definitions — "Mount Vesuvius is a somma–stratovolcano…",
# "An escarpment is a steep slope…". Subject is 1–4 words and the predicate
# starts with an article (a/an/the). Requiring the article keeps genuinely
# DYK-worthy "X is one of the world's…" sentences from being penalised.
LEAD_DEF = re.compile(
    r"^[A-Z][\w'‘’-]*"                                          # capitalised first word
    r"(?:\s+[\w'‘’-]+){0,3}"                                    # 0–3 further subject words (any case)
    r"\s+(?:is|are|was|were|refers\s+to|means|describes)"       # verb of being
    r"\s+(?:an?|the)\b"                                          # … + article
)

# Parenthesised IPA pronunciation blocks like "(/vəˈsuːviəs/ və-SOO-vee-əs)" —
# pure visual noise on a HUD. Detect by stress markers + unusual phonemes only;
# the bare slash is excluded so unit parentheticals like "(251 lb/cu ft)" or
# "(≈10–40 km/h)" survive as legitimate quantitative facts.
IPA_PARENS = re.compile(
    r"\s*\([^)]*[ˈˌɑəɛɪɔʊθðŋʃʒːæɒɜɝɚɹ][^)]*\)"
)


def clean(sentence: str) -> str:
    """Strip IPA pronunciation chunks and tighten whitespace. Idempotent."""
    s = IPA_PARENS.sub("", sentence)
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"\s+([,.;:!?])", r"\1", s)  # no space before punctuation
    return s.strip()


def split_sentences(paragraph: str) -> list[str]:
    """Lazy sentence splitter — Wikipedia paragraphs are clean enough that
    a regex on terminal punctuation followed by an upper-case start does
    the job. Avoids dragging in nltk/spacy for two regexes."""
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z(\d])", paragraph)
    return [p.strip() for p in parts if p.strip()]


def score(sentence: str) -> int:
    s = 0
    if NUMBERS.search(sentence):       s += 2
    if SUPERLATIVES.search(sentence):  s += 2
    if NAMED.search(sentence):         s += 2
    if PRONOUN_START.search(sentence): s -= 3
    if LEAD_DEF.match(sentence):       s -= 2
    if "(" in sentence and ")" in sentence: s += 1
    return s


def pick_dyk(facts: list[str], count: int) -> list[str]:
    sentences: list[str] = []
    for paragraph in facts:
        sentences.extend(split_sentences(paragraph))

    # Clean before length filter so an IPA-stripped sentence isn't rejected
    # for being "too long" because of pronunciation cruft we're about to drop.
    sentences = [clean(s) for s in sentences]

    # Drop broken refs and out-of-band lengths.
    sentences = [
        s for s in sentences
        if MIN_LEN <= len(s) <= MAX_LEN and not BROKEN_REF.match(s)
    ]

    # First-60-chars dedupe — Wikipedia summaries often repeat the lead
    # sentence verbatim across the summary and the first paragraph.
    seen: set[str] = set()
    unique: list[str] = []
    for s in sentences:
        key = s[:60].lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(s)

    return sorted(unique, key=score, reverse=True)[:count]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="Comma-separated subset of codewords")
    ap.add_argument("--keep", action="store_true",
                    help="Skip entries that already have a did_you_know array")
    ap.add_argument("--force", action="store_true",
                    help="Confirm overwriting existing did_you_know arrays. "
                         "Required unless --keep is also passed.")
    args = ap.parse_args()

    only_set: set[str] | None = None
    if args.only:
        only_set = {w.strip().lower() for w in args.only.split(",") if w.strip()}

    if not MANIFEST.exists():
        print(f"error: manifest not found at {MANIFEST}", file=sys.stderr)
        print(f"hint: run scripts/fetch_codeword_data.py first", file=sys.stderr)
        return 1

    if not args.force and not args.keep:
        print("warning: this overwrites did_you_know for every codeword in the "
              "manifest.", file=sys.stderr)
        print("         The shipped corpus is agent-authored (6 richer, grounded "
              "snippets/word) — this script is only the offline/no-API fallback "
              "and its heuristic output is thinner. See CLAUDE.md > Data pipeline.",
              file=sys.stderr)
        print("         Re-run with --force to overwrite anyway, or --keep to "
              "only fill entries that don't have did_you_know yet.", file=sys.stderr)
        return 1

    manifest = json.loads(MANIFEST.read_text())
    data = manifest.get("data", {})

    rebuilt, skipped, empty = 0, 0, 0
    for word, entry in sorted(data.items()):
        if only_set is not None and word not in only_set:
            continue
        if args.keep and entry.get("did_you_know"):
            skipped += 1
            continue
        dyk = pick_dyk(entry.get("facts") or [], DYK_COUNT)
        if not dyk:
            print(f"  [{word}] no usable sentences")
            empty += 1
            continue
        entry["did_you_know"] = dyk
        rebuilt += 1
        print(f"  [{word}] {len(dyk)} items")

    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"\n=== Done ===")
    print(f"  Rebuilt:          {rebuilt}")
    print(f"  Skipped (--keep): {skipped}")
    print(f"  Empty:            {empty}")
    print(f"  Manifest:         {MANIFEST.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
