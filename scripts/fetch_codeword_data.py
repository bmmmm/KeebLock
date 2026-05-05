#!/usr/bin/env python3
"""
One-shot fetcher for KeebLock codeword data.

For every word in `WORDS_BY_THEME` below, queries the English Wikipedia REST
API for a summary + lead image, then the page HTML for ~8–10 substantial
fact paragraphs. Images are downloaded into Resources/CodewordImages/ and
resized to 1200px wide via macOS `sips`. The JSON manifest goes to
Resources/codeword_data.json.

Words for which Wikipedia returns no extract or no lead image land in the
`unavailable` list. The app should filter them out at runtime — the user
will simply not get those words rolled as codewords.

Usage (from repo root):
    python3 scripts/fetch_codeword_data.py            # incremental (skip if image exists)
    python3 scripts/fetch_codeword_data.py --force    # re-fetch everything
    python3 scripts/fetch_codeword_data.py --only vesuvius,andes  # subset

Requires network access to en.wikipedia.org and upload.wikimedia.org.
Pure stdlib — no pip dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

USER_AGENT = "KeebLock-DataFetch/1.0 (open-source app; contact: hi@brtsz.de)"
REPO_ROOT = Path(__file__).resolve().parent.parent
RESOURCES_DIR = REPO_ROOT / "KeebLock" / "Resources"
IMAGES_DIR = RESOURCES_DIR / "CodewordImages"
MANIFEST_PATH = RESOURCES_DIR / "codeword_data.json"

# Mirrors KeebLock/Settings/Codewords.swift.
# Per-word slug overrides map to actual Wikipedia article titles where the
# bare word would 404 or land on a disambig page.
WORDS_BY_THEME: dict[str, list[str]] = {
    "volcanoes": [
        "vesuvius", "stromboli", "krakatoa", "kilauea", "pinatubo", "cotopaxi",
        "tambora", "hekla", "merapi", "surtsey", "ruapehu", "bromo",
        "erebus", "fuego", "rainier", "lassen", "katmai", "santorini",
        "novarupta", "tongariro", "redoubt", "izalco",
    ],
    "rocks": [
        "granite", "basalt", "gneiss", "marble", "slate", "limestone",
        "sandstone", "quartzite", "dolomite", "obsidian", "pumice", "travertine",
        "andesite", "diorite", "gabbro", "diabase", "rhyolite", "trachyte",
        "phonolite", "syenite", "anorthite",
    ],
    "minerals": [
        "quartz", "pyrite", "olivine", "calcite", "mica", "topaz",
        "beryl", "augite", "spinel", "apatite", "fluorite", "hematite",
        "magnetite", "limonite", "galena", "sphalerite", "malachite", "azurite",
        "corundum", "garnet", "albite", "microcline", "lazurite", "marcasite",
        "chalcedony", "rutile", "zircon", "ilmenite",
    ],
    "phenomena": [
        "caldera", "geyser", "lahar", "tephra", "magma", "eruption",
        "crater", "vent", "pluton", "laccolith", "tsunami", "fumarole",
        "solfatara", "mofette", "massif", "fissure",
    ],
    "ranges": [
        "andes", "alps", "atlas", "himalaya", "caucasus", "carpathians",
        "apennines", "pamir", "tienshan", "karakoram", "sierra", "vosges",
        "eifel", "taunus", "sudetes", "kunlun",
    ],
}

SLUG_OVERRIDES: dict[str, str] = {
    "vesuvius":   "Mount Vesuvius",
    "stromboli":  "Stromboli",
    "krakatoa":   "Krakatoa",
    "kilauea":    "Kīlauea",
    "pinatubo":   "Mount Pinatubo",
    "cotopaxi":   "Cotopaxi",
    "tambora":    "Mount Tambora",
    "hekla":      "Hekla",
    "merapi":     "Mount Merapi",
    "surtsey":    "Surtsey",
    "ruapehu":    "Mount Ruapehu",
    "bromo":      "Mount Bromo",
    "erebus":     "Mount Erebus",
    "fuego":      "Volcán de Fuego",
    "rainier":    "Mount Rainier",
    "lassen":     "Lassen Peak",
    "katmai":     "Mount Katmai",
    "santorini":  "Santorini",
    "novarupta":  "Novarupta",
    "tongariro":  "Mount Tongariro",
    "redoubt":    "Mount Redoubt",
    "izalco":     "Izalco (volcano)",
    "andes":      "Andes",
    "alps":       "Alps",
    "atlas":      "Atlas Mountains",
    "himalaya":   "Himalayas",
    "caucasus":   "Caucasus Mountains",
    "carpathians":"Carpathian Mountains",
    "apennines":  "Apennine Mountains",
    "pamir":      "Pamir Mountains",
    "tienshan":   "Tian Shan",
    "karakoram":  "Karakoram",
    "sierra":     "Sierra Nevada (U.S.)",
    "vosges":     "Vosges",
    "eifel":      "Eifel",
    "taunus":     "Taunus",
    "sudetes":    "Sudetes",
    "kunlun":     "Kunlun Mountains",
}


# ---------- HTTP helpers ----------

def http_get(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def http_get_json(url: str) -> dict:
    return json.loads(http_get(url).decode("utf-8"))


def wiki_summary(title: str) -> dict:
    """REST: /api/rest_v1/page/summary/{title}. Raises on 404."""
    encoded = urllib.parse.quote(title.replace(" ", "_"), safe=":()")
    return http_get_json(f"https://en.wikipedia.org/api/rest_v1/page/summary/{encoded}")


def wiki_html(title: str) -> str:
    encoded = urllib.parse.quote(title.replace(" ", "_"), safe=":()")
    return http_get(f"https://en.wikipedia.org/api/rest_v1/page/html/{encoded}").decode("utf-8")


# ---------- Fact extraction ----------

class _ParagraphCollector(HTMLParser):
    """Collects text from top-level <p> tags inside the main article body.

    Skips paragraphs inside <table>, <figure>, <aside>, <ol class="references">,
    drops citation markers like [1][2], and ignores stub paragraphs (<120 chars
    after cleanup) so we get substantive sentences not fragments.
    """

    SKIP_TAGS = {"table", "figure", "aside", "div", "sup"}

    def __init__(self) -> None:
        super().__init__()
        self.paragraphs: list[str] = []
        self._in_p = False
        self._current: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs):
        if tag == "p" and self._skip_depth == 0:
            self._in_p = True
            self._current = []
        elif tag in self.SKIP_TAGS:
            self._skip_depth += 1
        elif tag == "ol":
            attrs_dict = dict(attrs)
            if "references" in (attrs_dict.get("class") or ""):
                self._skip_depth += 1

    def handle_endtag(self, tag: str):
        if tag == "p" and self._in_p:
            self._in_p = False
            text = "".join(self._current).strip()
            text = re.sub(r"\[\d+\]", "", text)         # strip citation markers
            text = re.sub(r"\s+", " ", text)            # collapse whitespace
            if len(text) >= 120:
                self.paragraphs.append(text)
            self._current = []
        elif tag in self.SKIP_TAGS or tag == "ol":
            self._skip_depth = max(0, self._skip_depth - 1)

    def handle_data(self, data: str):
        if self._in_p and self._skip_depth == 0:
            self._current.append(data)


def extract_facts(html: str, limit: int = 10) -> list[str]:
    parser = _ParagraphCollector()
    parser.feed(html)
    return parser.paragraphs[:limit]


# ---------- Image handling ----------

def download_image(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(http_get(url, timeout=60))


def resize_image(target: Path, max_width: int = 800) -> None:
    """macOS `sips` resize in place."""
    subprocess.run(
        ["sips", "--resampleWidth", str(max_width), str(target)],
        check=True, capture_output=True,
    )


# ---------- Per-word fetch ----------

def fetch_word(word: str, force: bool) -> dict | None:
    """Returns the manifest entry on success, None on unavailable."""
    title = SLUG_OVERRIDES.get(word, word.capitalize())
    print(f"  [{word}] → {title}", flush=True)

    try:
        summary = wiki_summary(title)
    except Exception as e:
        print(f"      summary fetch failed: {e}", flush=True)
        return None

    extract = (summary.get("extract") or "").strip()
    if len(extract) < 80:
        print(f"      extract too short ({len(extract)} chars) — skipping", flush=True)
        return None

    image_meta = summary.get("originalimage") or summary.get("thumbnail")
    if not image_meta or not image_meta.get("source"):
        print(f"      no lead image — skipping", flush=True)
        return None

    image_url = image_meta["source"]
    image_filename = f"{word}.jpg"
    image_target = IMAGES_DIR / image_filename
    if force or not image_target.exists():
        try:
            download_image(image_url, image_target)
            resize_image(image_target)
        except Exception as e:
            print(f"      image fetch/resize failed: {e}", flush=True)
            if image_target.exists():
                image_target.unlink()
            return None

    try:
        html = wiki_html(title)
    except Exception as e:
        print(f"      html fetch failed: {e}", flush=True)
        return None

    facts = extract_facts(html, limit=10)
    if len(facts) < 3:
        print(f"      only {len(facts)} usable paragraphs — skipping", flush=True)
        if image_target.exists():
            image_target.unlink()
        return None

    return {
        "title": summary.get("title") or title,
        "summary": extract,
        "wikipedia_url": summary.get("content_urls", {}).get("desktop", {}).get("page")
                         or f"https://en.wikipedia.org/wiki/{urllib.parse.quote(title.replace(' ', '_'))}",
        "image_filename": image_filename,
        "image_source_url": image_url,
        "facts": facts,
    }


# ---------- Main ----------

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--force", action="store_true", help="Re-download even if image exists")
    p.add_argument("--only", help="Comma-separated subset of words")
    args = p.parse_args()

    only_set: set[str] | None = None
    if args.only:
        only_set = {w.strip().lower() for w in args.only.split(",") if w.strip()}

    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    data: dict[str, dict] = {}
    unavailable: list[str] = []

    # Preserve previous manifest data when running subset (--only).
    if only_set and MANIFEST_PATH.exists():
        prev = json.loads(MANIFEST_PATH.read_text())
        data.update(prev.get("data", {}))
        unavailable = list(prev.get("unavailable", []))

    for theme, words in WORDS_BY_THEME.items():
        print(f"\n=== {theme} ({len(words)} words) ===", flush=True)
        for word in words:
            if only_set is not None and word not in only_set:
                continue
            entry = fetch_word(word, force=args.force)
            if entry is None:
                if word not in unavailable:
                    unavailable.append(word)
                if word in data:
                    del data[word]
            else:
                entry["theme"] = theme
                data[word] = entry
                if word in unavailable:
                    unavailable.remove(word)
            time.sleep(0.2)  # be polite to Wikipedia

    manifest = {
        "version": 1,
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "https://en.wikipedia.org/api/rest_v1",
        "data": dict(sorted(data.items())),
        "unavailable": sorted(set(unavailable)),
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, ensure_ascii=False))

    print(f"\n=== Done ===")
    print(f"  Available:    {len(data)}")
    print(f"  Unavailable:  {len(unavailable)}: {', '.join(unavailable) or '—'}")
    print(f"  Manifest:     {MANIFEST_PATH.relative_to(REPO_ROOT)}")
    print(f"  Images:       {IMAGES_DIR.relative_to(REPO_ROOT)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
