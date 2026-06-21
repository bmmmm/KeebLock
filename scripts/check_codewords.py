#!/usr/bin/env python3
"""Guard against codeword/manifest drift.

`Codewords.all` (Swift) and the bundled `codeword_data.json` manifest are two
hand-maintained lists that must stay in sync: every word offered as a codeword
needs a knowledge entry, or the lock HUD renders an empty stub. This script is
run by build.sh before each build and fails the build on any divergence.

Exit codes:
  0  in sync (manifest may contain extra unused words — warned, not fatal)
  1  one or more Swift codewords lack a manifest entry (hard fail)
  2  could not parse one of the inputs
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT = REPO / "KeebLock" / "Settings" / "Codewords.swift"
MANIFEST = REPO / "KeebLock" / "Resources" / "codeword_data.json"


def swift_words() -> set[str]:
    src = SWIFT.read_text()
    m = re.search(r"static let all:\s*\[String\]\s*=\s*\[(.*?)\n\s*\]", src, re.S)
    if not m:
        print(f"check_codewords: could not locate `all` array in {SWIFT}", file=sys.stderr)
        sys.exit(2)
    return set(re.findall(r'"([a-z0-9-]+)"', m.group(1)))


def manifest_words() -> set[str]:
    try:
        doc = json.loads(MANIFEST.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"check_codewords: could not read manifest {MANIFEST}: {exc}", file=sys.stderr)
        sys.exit(2)
    return {w.lower() for w in doc.get("data", {})}


def main() -> int:
    swift = swift_words()
    manifest = manifest_words()

    broken = sorted(swift - manifest)   # offered as codeword, no data -> stub HUD
    unused = sorted(manifest - swift)   # data bundled, never usable as codeword

    if unused:
        print(f"check_codewords: warning: {len(unused)} manifest word(s) never used as codeword "
              f"(wasted bundle data): {', '.join(unused)}")

    if broken:
        print(f"check_codewords: ERROR: {len(broken)} codeword(s) have no manifest entry and would "
              f"render as an empty HUD stub: {', '.join(broken)}", file=sys.stderr)
        print("  Fix: add them to WORDS_BY_THEME and run scripts/fetch_codeword_data.py, "
              "or remove them from Codewords.all.", file=sys.stderr)
        return 1

    print(f"check_codewords: OK — {len(swift)} codewords, all backed by manifest data")
    return 0


if __name__ == "__main__":
    sys.exit(main())
