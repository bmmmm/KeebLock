"""Tests for the DYK-snippet heuristics in build_dyk.py.

Fixture-driven only — no manifest file I/O, no network.
"""

from __future__ import annotations

import build_dyk as dyk


# ---------- IPA_PARENS: strip pronunciation, keep unit parentheticals ----------

def test_ipa_pronunciation_parenthetical_is_stripped():
    s = "Vesuvius (/vəˈsuːviəs/ və-SOO-vee-əs) is a stratovolcano in Italy."
    cleaned = dyk.clean(s)
    assert "vəˈsuːviəs" not in cleaned
    assert "Vesuvius is a stratovolcano in Italy." == cleaned


def test_unit_parenthetical_with_bare_slash_survives():
    # The bare slash alone must not trigger IPA_PARENS -- only actual IPA
    # stress-mark/phoneme characters do. This is the exact class named in the
    # task: "(251 lb/cu ft)" density units, not pronunciation guides.
    s = "Pumice has a density of about 0.25 g/cm3 (251 lb/cu ft) when dry."
    cleaned = dyk.clean(s)
    assert "(251 lb/cu ft)" in cleaned


def test_unit_parenthetical_with_range_and_slash_survives():
    s = "Lahars can travel at speeds of (≈10–40 km/h) down steep valley slopes."
    cleaned = dyk.clean(s)
    assert "(≈10–40 km/h)" in cleaned


def test_ipa_with_stress_mark_only_is_stripped_even_without_slash():
    s = "Krakatoa (krækəˈtoʊə) erupted catastrophically in 1883."
    cleaned = dyk.clean(s)
    assert "krækəˈtoʊə" not in cleaned
    assert "Krakatoa erupted catastrophically in 1883." == cleaned


def test_clean_collapses_whitespace_and_tightens_punctuation():
    s = "Some   text   with   odd spacing , and punctuation ."
    cleaned = dyk.clean(s)
    assert cleaned == "Some text with odd spacing, and punctuation."


def test_clean_is_idempotent():
    s = "Vesuvius (/vəˈsuːviəs/) is a volcano near Naples , Italy ."
    once = dyk.clean(s)
    twice = dyk.clean(once)
    assert once == twice


# ---------- split_sentences ----------

def test_split_sentences_basic():
    paragraph = "First sentence here. Second sentence follows! Third one too?"
    parts = dyk.split_sentences(paragraph)
    assert parts == [
        "First sentence here.",
        "Second sentence follows!",
        "Third one too?",
    ]


# ---------- score ----------

def test_score_rewards_numbers_superlatives_and_named():
    assert dyk.score("It erupted in 1883.") < dyk.score(
        "Krakatoa is the largest recorded eruption, named after the island."
    )


def test_score_penalizes_pronoun_start():
    assert dyk.score("It was discovered in 1815 by local surveyors.") < dyk.score(
        "Tambora was discovered in 1815 by local surveyors."
    )


def test_score_penalizes_lead_definition_sentences():
    lead = "An escarpment is a steep slope separating two levels of ground."
    other = "Escarpments can expose 500 million years of rock strata to view."
    assert dyk.score(lead) < dyk.score(other)


# ---------- pick_dyk end-to-end ----------

def test_pick_dyk_filters_broken_refs_and_short_or_long_sentences():
    facts = [
        "(2003) suggest that warm spring water is not particularly useful here.",
        "Too short.",
        "A" * 500 + ".",
        "The geyser erupts roughly every 90 minutes, making it one of the most "
        "predictable in the entire park according to long-term observation data.",
    ]
    picked = dyk.pick_dyk(facts, count=6)
    assert len(picked) == 1
    assert picked[0].startswith("The geyser erupts")


def test_pick_dyk_dedupes_by_first_60_chars():
    facts = [
        "The volcano last erupted in 1991 and displaced hundreds of thousands "
        "of people living nearby in the surrounding lowland villages and towns.",
        "The volcano last erupted in 1991 and displaced hundreds of thousands "
        "of nearby residents according to a separate independent government report.",
    ]
    picked = dyk.pick_dyk(facts, count=6)
    assert len(picked) == 1


def test_pick_dyk_respects_count_limit():
    facts = [
        f"This is unique sentence number {i} about volcanic rock formations "
        "found across many different mountain ranges worldwide in various eras."
        for i in range(10)
    ]
    picked = dyk.pick_dyk(facts, count=3)
    assert len(picked) == 3


def test_pick_dyk_empty_facts_returns_empty():
    assert dyk.pick_dyk([], count=6) == []
