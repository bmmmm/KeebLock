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
        "novarupta", "tongariro", "redoubt", "etna",
    ],
    "rocks": [
        "granite", "basalt", "gneiss", "marble", "slate", "limestone",
        "sandstone", "quartzite", "dolomite", "obsidian", "pumice", "travertine",
        "andesite", "diorite", "gabbro", "diabase", "rhyolite", "trachyte",
        "phonolite", "syenite", "chert",
    ],
    "minerals": [
        "quartz", "pyrite", "olivine", "calcite", "mica", "topaz",
        "beryl", "tourmaline", "spinel", "apatite", "fluorite", "hematite",
        "magnetite", "limonite", "galena", "sphalerite", "malachite", "azurite",
        "corundum", "garnet", "albite", "microcline", "lazurite", "marcasite",
        "chalcedony", "rutile", "zircon", "ilmenite",
    ],
    "phenomena": [
        "hotspring", "geyser", "lahar", "tephra", "magma", "eruption",
        "crater", "vent", "pluton", "laccolith", "tsunami", "fumarole",
        "solfatara", "sinkhole", "escarpment", "fissure",
        "earthquake", "lapilli", "avalanche", "landslide", "mudflow",
        "rockfall", "subsidence", "seiche", "lavaflow", "erosion",
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
    "etna":       "Mount Etna",
    "dolomite":   "Dolomite (mineral)",
    "vent":       "Volcanic vent",
    "hotspring":  "Hot spring",
    "lavaflow":   "Lava",
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
            if len(text) >= 80:
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


# ---------- Image attribution (Wikimedia Commons) ----------
#
# Wikipedia summary's `originalimage.source` lands on upload.wikimedia.org —
# that's the binary, not the metadata. License/author/credit live on the
# Commons "File:" page, queried via the Commons MediaWiki API. We need them
# because Wikimedia images carry per-file licenses (PD, CC0, CC BY, CC BY-SA,
# …) that are NOT covered by the repo's Apache-2.0 license. Without recorded
# attribution we cannot legally redistribute the binaries inside the app.

def commons_filename_from_url(url: str) -> str:
    """Extract the Commons file name from any upload.wikimedia.org URL.

    Handles direct and thumbnail forms:
        /wikipedia/commons/x/yy/<filename>
        /wikipedia/commons/thumb/x/yy/<filename>/<width>px-<filename>
    """
    path = urllib.parse.urlparse(url).path
    parts = [p for p in path.split("/") if p]
    if "commons" not in parts:
        return urllib.parse.unquote(parts[-1] if parts else "")
    idx = parts.index("commons") + 1
    if idx < len(parts) and parts[idx] == "thumb":
        # thumb / x / yy / filename / WIDTHpx-filename  → take "filename"
        return urllib.parse.unquote(parts[idx + 3]) if idx + 3 < len(parts) else ""
    # x / yy / filename
    return urllib.parse.unquote(parts[idx + 2]) if idx + 2 < len(parts) else ""


def commons_imageinfo(file_basename: str) -> dict | None:
    """Query Commons API for a file's imageinfo (license, artist, credit).

    `file_basename` is the bare filename without "File:" prefix, e.g.
    `Albite_-_Crete_(Kriti)_Island,_Greece.jpg`. Returns None if the file is
    unknown or the API failed; callers should treat that as "attribution
    missing" rather than fail the whole entry.
    """
    qs = urllib.parse.urlencode({
        "action": "query",
        "format": "json",
        "titles": f"File:{file_basename}",
        "prop": "imageinfo",
        "iiprop": "extmetadata|user|url",
        "iiextmetadatafilter": "License|LicenseShortName|LicenseUrl|Artist|Credit|AttributionRequired",
        "iiextmetadatalanguage": "en",
    })
    try:
        resp = http_get_json(f"https://commons.wikimedia.org/w/api.php?{qs}")
    except Exception as e:
        print(f"      commons api failed: {e}", flush=True)
        return None
    pages = resp.get("query", {}).get("pages", {})
    if not pages:
        return None
    page = next(iter(pages.values()))
    if page.get("missing") is not None:
        return None
    info = page.get("imageinfo") or []
    if not info:
        return None
    return {
        "pageid": page.get("pageid"),
        "title": page.get("title") or f"File:{file_basename}",
        "imageinfo": info[0],
    }


def _strip_html(s: str) -> str:
    if not s:
        return ""
    txt = re.sub(r"<[^>]+>", "", s)
    for entity, repl in (("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                         ("&quot;", '"'), ("&#39;", "'"), ("&nbsp;", " ")):
        txt = txt.replace(entity, repl)
    return re.sub(r"\s+", " ", txt).strip()


def _parse_html_artist(html: str) -> tuple[str, str | None]:
    """Pull a clean author name + optional URL from the Artist HTML blob."""
    if not html:
        return "", None
    url = None
    m = re.search(r'<a\s+[^>]*href="([^"]+)"', html)
    if m:
        url = m.group(1)
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = "https://commons.wikimedia.org" + url
    return _strip_html(html), url


def _parse_bool(s: str) -> bool | None:
    if not s:
        return None
    s = s.strip().lower()
    if s in ("true", "1", "yes"):
        return True
    if s in ("false", "0", "no"):
        return False
    return None


def build_attribution(file_basename: str, info: dict) -> dict:
    """Translate a commons_imageinfo() result into the JSON shape we store."""
    ii = info.get("imageinfo") or {}
    em = ii.get("extmetadata") or {}

    def emval(key: str) -> str:
        v = em.get(key)
        return v.get("value", "") if isinstance(v, dict) else ""

    artist_name, artist_url = _parse_html_artist(emval("Artist"))
    license_id = emval("License")  # e.g. "cc-by-sa-4.0"
    file_title = info.get("title") or f"File:{file_basename}"
    page_url = "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(
        file_title.replace(" ", "_"), safe=":/"
    )

    return {
        "commons_file_title":   file_title,
        "commons_page_url":     page_url,
        "commons_pageid":       info.get("pageid"),
        "uploader":             ii.get("user") or None,
        "author":               artist_name or None,
        "author_url":           artist_url,
        "license_name":         emval("LicenseShortName") or None,
        "license_url":          emval("LicenseUrl") or None,
        "license_spdx":         license_id.upper() if license_id else None,
        "credit":               _strip_html(emval("Credit")) or None,
        "attribution_required": _parse_bool(emval("AttributionRequired")),
    }


def fetch_attribution_only(image_source_url: str | None) -> dict | None:
    """Backfill attribution for an existing entry — no Wikipedia summary/html.

    Used by main() to fill in `image_attribution` for previously-fetched
    words whose entry predates the attribution schema. Only the Commons
    API is hit, so this is much cheaper than a full re-fetch.
    """
    if not image_source_url:
        return None
    file_basename = commons_filename_from_url(image_source_url)
    if not file_basename:
        return None
    info = commons_imageinfo(file_basename)
    if info is None:
        return None
    return build_attribution(file_basename, info)


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

    # Attribution lookup is best-effort: a missing Commons response should
    # not invalidate the whole entry, but downstream tooling (CREDITS.md
    # generator, in-app credits view) must flag null attribution as needing
    # manual review before public distribution.
    file_basename = commons_filename_from_url(image_url)
    attribution: dict | None = None
    if file_basename:
        info = commons_imageinfo(file_basename)
        if info is not None:
            attribution = build_attribution(file_basename, info)
        else:
            print(f"      attribution lookup empty for {file_basename}", flush=True)
    else:
        print(f"      could not derive Commons filename from {image_url}", flush=True)

    try:
        html = wiki_html(title)
    except Exception as e:
        print(f"      html fetch failed: {e}", flush=True)
        return None

    facts = extract_facts(html, limit=10)
    # Need at least 6 facts so the in-app rotation has variety. Below that,
    # the user would see the same handful repeat in any session longer than
    # 3 minutes.
    if len(facts) < 6:
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
        "image_attribution": attribution,
        "facts": facts,
    }


# ---------- Main ----------

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--force", action="store_true",
                   help="Re-fetch every word from scratch — ignores prev manifest "
                        "and overwrites all entries. Use only when you need a clean rebuild.")
    p.add_argument("--only", help="Comma-separated subset of words")
    args = p.parse_args()

    only_set: set[str] | None = None
    if args.only:
        only_set = {w.strip().lower() for w in args.only.split(",") if w.strip()}

    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    data: dict[str, dict] = {}
    unavailable: list[str] = []

    # Default behaviour preserves the previous manifest so re-running the
    # script never destroys hand-curated or already-attributed entries.
    # `--force` opts out of that and rebuilds from scratch.
    if not args.force and MANIFEST_PATH.exists():
        prev = json.loads(MANIFEST_PATH.read_text())
        data.update(prev.get("data", {}))
        unavailable = list(prev.get("unavailable", []))

    for theme, words in WORDS_BY_THEME.items():
        print(f"\n=== {theme} ({len(words)} words) ===", flush=True)
        for word in words:
            if only_set is not None and word not in only_set:
                continue

            existing = data.get(word)
            image_target = IMAGES_DIR / f"{word}.jpg"

            # Skip work that's already done. An entry is "complete" when its
            # image is on disk AND it has a non-null image_attribution block.
            # Anything missing → backfill the cheap path (attribution-only)
            # if we have an image_source_url, else fall through to full fetch.
            if not args.force and existing is not None and image_target.exists():
                if existing.get("image_attribution") is not None:
                    print(f"  [{word}] cached (complete)", flush=True)
                    continue
                attribution = fetch_attribution_only(existing.get("image_source_url"))
                if attribution is not None:
                    existing["image_attribution"] = attribution
                    print(f"  [{word}] attribution backfilled", flush=True)
                else:
                    print(f"  [{word}] attribution still unavailable", flush=True)
                time.sleep(0.2)
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

    # Drop entries whose word no longer appears in WORDS_BY_THEME so the
    # manifest stays in sync after replacements (e.g. izalco → etna).
    valid_words = {w for ws in WORDS_BY_THEME.values() for w in ws}
    obsolete_data = sorted(set(data) - valid_words)
    obsolete_unavail = sorted(set(unavailable) - valid_words)
    for w in obsolete_data:
        del data[w]
    unavailable = [w for w in unavailable if w in valid_words]
    if obsolete_data or obsolete_unavail:
        print(f"\nDropped obsolete: data={obsolete_data}, unavailable={obsolete_unavail}")

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
