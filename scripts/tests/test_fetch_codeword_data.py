"""Tests for the HTML parsing / attribution helpers in fetch_codeword_data.py.

Fixture-driven only — no network calls. Every fixture is a fixed HTML string
fed directly into extract_facts()/_ParagraphCollector, or a fixed dict fed
into the attribution helpers.
"""

from __future__ import annotations

import fetch_codeword_data as fcd


# ---------- superscript / subscript transliteration ----------
# Regression coverage for the documented bug: SKIP_TAGS used to include
# "sup", silently deleting exponents — "6×10<sup>5</sup>" collapsed to "6×10"
# (see CLAUDE.md pitfalls + commit 2aaa491).

def test_superscript_exponent_becomes_unicode():
    html = (
        "<p>The eruption released about 6×10<sup>5</sup> m<sup>3</sup> of magma "
        "per second, according to studies of the volcanic vent system near the "
        "crater during that catastrophic year of unusually intense activity.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "6×10⁵ m³" in facts[0]
    assert "<sup>" not in facts[0]


def test_subscript_chemical_formula_becomes_unicode():
    html = (
        "<p>The mineral composition is dominated by silicon dioxide, chemically "
        "written as SiO<sub>2</sub>, which forms the bulk of the surrounding "
        "country rock in this particular geological formation near the summit.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "SiO₂" in facts[0]
    assert "<sub>" not in facts[0]


def test_nested_sup_does_not_reset_outer_buffer():
    # A nested inline tag inside <sup> (e.g. an <i>) must not clobber the
    # already-open script buffer, per the comment in handle_starttag.
    html = (
        "<p>The measured flux was about 4×10<sup>2<i>a</i></sup> units, based on "
        "field surveys conducted over several decades near the caldera rim area.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "4×10²ᵃ" in facts[0]


def test_to_script_falls_back_to_raw_text_for_exotic_chars():
    # Mapping only covers 0-9 and a handful of letters/symbols; anything else
    # degrades to plain text instead of raising or corrupting the output.
    assert fcd._to_script("5", fcd._SUPERSCRIPT) == "⁵"
    assert fcd._to_script("Q", fcd._SUPERSCRIPT) == "Q"  # not in mapping -> raw
    assert fcd._to_script("", fcd._SUPERSCRIPT) == ""


# ---------- citation marker stripping ----------

def test_reference_sup_is_dropped_entirely():
    html = (
        "<p>Some text about the crater.<sup class=\"mw-ref reference\">[1]</sup> "
        "More text follows to make this paragraph long enough to pass the eighty "
        "character threshold required for inclusion in the extracted facts.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "[1]" not in facts[0]
    assert "reference" not in facts[0]


def test_literal_bracket_citation_marker_is_regex_stripped():
    # Citation markers that already appear as bare text (not wrapped in a
    # <sup>) are stripped by the post-processing regex in handle_endtag.
    html = (
        "<p>Some text about the crater[2] and its long eruptive history spanning "
        "many centuries of documented volcanic activity in the surrounding region.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "[2]" not in facts[0]


# ---------- tag stripping (SKIP_TAGS + references list) ----------

def test_table_content_inside_paragraph_is_skipped():
    html = (
        "<p>Text before the nested table content that should survive extraction "
        "in full.<table><tr><td>hidden table cell text</td></tr></table> Text "
        "after the table also survives and keeps the paragraph long enough.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "hidden table cell text" not in facts[0]
    assert "Text before the nested table" in facts[0]
    assert "Text after the table" in facts[0]


def test_figure_and_aside_content_is_skipped():
    html = (
        "<p>Lead paragraph text that continues on with enough substance to pass "
        "the minimum length filter for extraction into the facts array output."
        "<figure><figcaption>A caption nobody should see</figcaption></figure>"
        "<aside>An aside nobody should see either</aside></p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "caption nobody should see" not in facts[0]
    assert "aside nobody should see" not in facts[0]


def test_references_ordered_list_is_skipped():
    html = (
        "<p>Paragraph one has plenty of substantial content describing the "
        "volcano's eruptive history across several centuries of documented "
        "activity in the region surrounding the crater.</p>"
        "<ol class=\"references\"><li>Some Author, Some Journal, 2001.</li></ol>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "Some Author" not in facts[0]


def test_div_wrapping_a_paragraph_suppresses_extraction():
    # SKIP_TAGS includes "div" (undocumented in the class docstring, which
    # only mentions table/figure/aside/ol.references). Any top-level <div>
    # ancestor before the <p> keeps skip_depth > 0 for the whole paragraph,
    # so it is never collected. Documents actual current behavior — not
    # asserting this is (or isn't) a real-world defect, see task report.
    html = (
        "<div><p>This paragraph has more than enough characters to normally "
        "qualify for inclusion in the extracted facts list output array.</p></div>"
    )
    facts = fcd.extract_facts(html)
    assert facts == []


# ---------- stub filtering (<80 chars) ----------

def test_short_paragraph_is_dropped():
    html = "<p>Too short.</p>"
    assert fcd.extract_facts(html) == []


def test_whitespace_is_collapsed():
    html = (
        "<p>This    paragraph   has\n\nirregular\twhitespace scattered throughout "
        "its body text but is still long enough to clear the minimum length "
        "filter applied by the paragraph collector during extraction.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "  " not in facts[0]
    assert "\n" not in facts[0]
    assert "\t" not in facts[0]


def test_limit_truncates_paragraph_count():
    paragraph = (
        "<p>This is a sufficiently long paragraph about volcanic rock formations "
        "and their mineral composition across many different regions worldwide.</p>"
    )
    html = paragraph * 5
    facts = fcd.extract_facts(html, limit=3)
    assert len(facts) == 3


# ---------- HTML entity decoding (stdlib HTMLParser convert_charrefs) ----------

def test_named_and_numeric_entities_decode_in_paragraph_text():
    html = (
        "<p>Basalt &amp; andesite are common volcanic rocks; the term &#8220;a&#8217;a&#8221; "
        "describes a rough, rubbly lava surface type found in many eruptions worldwide.</p>"
    )
    facts = fcd.extract_facts(html)
    assert len(facts) == 1
    assert "Basalt & andesite" in facts[0]
    assert "&amp;" not in facts[0]
    assert "a’a" in facts[0] or "a'a" in facts[0]


# ---------- _strip_html (used for Commons attribution HTML) ----------

def test_strip_html_removes_tags_and_decodes_entities():
    raw = '<a href="https://example.com">Jane &amp; Bob&#39;s Photo</a>'
    assert fcd._strip_html(raw) == "Jane & Bob's Photo"


def test_strip_html_empty_input():
    assert fcd._strip_html("") == ""
    assert fcd._strip_html(None) == ""


def test_strip_html_collapses_whitespace():
    raw = "<b>Some   \n text</b>&nbsp;here"
    assert fcd._strip_html(raw) == "Some text here"


# ---------- commons_filename_from_url ----------

def test_commons_filename_direct_form():
    url = "https://upload.wikimedia.org/wikipedia/commons/a/ab/Mount_Vesuvius.jpg"
    assert fcd.commons_filename_from_url(url) == "Mount_Vesuvius.jpg"


def test_commons_filename_thumb_form():
    url = (
        "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/"
        "Mount_Vesuvius.jpg/1200px-Mount_Vesuvius.jpg"
    )
    assert fcd.commons_filename_from_url(url) == "Mount_Vesuvius.jpg"


def test_commons_filename_no_commons_segment_falls_back_to_last_path_part():
    url = "https://example.com/some/other/path/file.jpg"
    assert fcd.commons_filename_from_url(url) == "file.jpg"


# ---------- _parse_html_artist / _parse_bool / build_attribution ----------

def test_parse_html_artist_extracts_name_and_absolute_url():
    html = '<a href="//commons.wikimedia.org/wiki/User:Jane">Jane Doe</a>'
    name, url = fcd._parse_html_artist(html)
    assert name == "Jane Doe"
    assert url == "https://commons.wikimedia.org/wiki/User:Jane"


def test_parse_html_artist_relative_url_gets_commons_prefix():
    html = '<a href="/wiki/User:Jane">Jane Doe</a>'
    _, url = fcd._parse_html_artist(html)
    assert url == "https://commons.wikimedia.org/wiki/User:Jane"


def test_parse_html_artist_empty_input():
    assert fcd._parse_html_artist("") == ("", None)


def test_parse_bool_variants():
    assert fcd._parse_bool("true") is True
    assert fcd._parse_bool("Yes") is True
    assert fcd._parse_bool("0") is False
    assert fcd._parse_bool("no") is False
    assert fcd._parse_bool("") is None
    assert fcd._parse_bool("maybe") is None


def test_build_attribution_shape():
    info = {
        "pageid": 42,
        "title": "File:Mount_Vesuvius.jpg",
        "imageinfo": {
            "user": "SomeUploader",
            "extmetadata": {
                "Artist": {"value": '<a href="//commons.wikimedia.org/wiki/User:Jane">Jane Doe</a>'},
                "License": {"value": "cc-by-sa-4.0"},
                "LicenseShortName": {"value": "CC BY-SA 4.0"},
                "LicenseUrl": {"value": "https://creativecommons.org/licenses/by-sa/4.0"},
                "Credit": {"value": "Own work"},
                "AttributionRequired": {"value": "true"},
            },
        },
    }
    attribution = fcd.build_attribution("Mount_Vesuvius.jpg", info)
    assert attribution["author"] == "Jane Doe"
    assert attribution["license_spdx"] == "CC-BY-SA-4.0"
    assert attribution["license_name"] == "CC BY-SA 4.0"
    assert attribution["uploader"] == "SomeUploader"
    assert attribution["attribution_required"] is True
    assert attribution["commons_page_url"] == (
        "https://commons.wikimedia.org/wiki/File:Mount_Vesuvius.jpg"
    )


def test_build_attribution_missing_extmetadata_degrades_gracefully():
    info = {"pageid": 1, "title": "File:X.jpg", "imageinfo": {}}
    attribution = fcd.build_attribution("X.jpg", info)
    assert attribution["author"] is None
    assert attribution["license_spdx"] is None
    assert attribution["attribution_required"] is None
