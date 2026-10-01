"""Tests for check_codewords.py drift-detection logic.

SWIFT/MANIFEST module-level paths are monkeypatched to temp fixture files so
no production file (Codewords.swift, codeword_data.json) is touched.
"""

from __future__ import annotations

import json

import check_codewords as cc

SWIFT_FIXTURE = """\
import Foundation

enum Codewords {
    static let all: [String] = [
        "vesuvius", "granite", "quartz",
    ]
}
"""


def _write_manifest(path, words):
    path.write_text(json.dumps({"data": {w: {} for w in words}}))


def test_swift_words_parses_all_array(tmp_path, monkeypatch):
    swift_file = tmp_path / "Codewords.swift"
    swift_file.write_text(SWIFT_FIXTURE)
    monkeypatch.setattr(cc, "SWIFT", swift_file)
    assert cc.swift_words() == {"vesuvius", "granite", "quartz"}


def test_swift_words_missing_array_exits_with_code_2(tmp_path, monkeypatch, capsys):
    swift_file = tmp_path / "Codewords.swift"
    swift_file.write_text("enum Codewords { static let other = [] }")
    monkeypatch.setattr(cc, "SWIFT", swift_file)
    try:
        cc.swift_words()
        assert False, "expected SystemExit"
    except SystemExit as e:
        assert e.code == 2


def test_manifest_words_lowercases_keys(tmp_path, monkeypatch):
    manifest_file = tmp_path / "codeword_data.json"
    manifest_file.write_text(json.dumps({"data": {"Vesuvius": {}, "granite": {}}}))
    monkeypatch.setattr(cc, "MANIFEST", manifest_file)
    assert cc.manifest_words() == {"vesuvius", "granite"}


def test_manifest_words_bad_json_exits_with_code_2(tmp_path, monkeypatch):
    manifest_file = tmp_path / "codeword_data.json"
    manifest_file.write_text("{not valid json")
    monkeypatch.setattr(cc, "MANIFEST", manifest_file)
    try:
        cc.manifest_words()
        assert False, "expected SystemExit"
    except SystemExit as e:
        assert e.code == 2


def test_main_returns_0_when_in_sync(tmp_path, monkeypatch, capsys):
    swift_file = tmp_path / "Codewords.swift"
    swift_file.write_text(SWIFT_FIXTURE)
    manifest_file = tmp_path / "codeword_data.json"
    _write_manifest(manifest_file, ["vesuvius", "granite", "quartz"])
    monkeypatch.setattr(cc, "SWIFT", swift_file)
    monkeypatch.setattr(cc, "MANIFEST", manifest_file)
    assert cc.main() == 0
    assert "OK" in capsys.readouterr().out


def test_main_returns_1_when_codeword_missing_manifest_entry(tmp_path, monkeypatch, capsys):
    swift_file = tmp_path / "Codewords.swift"
    swift_file.write_text(SWIFT_FIXTURE)
    manifest_file = tmp_path / "codeword_data.json"
    _write_manifest(manifest_file, ["vesuvius", "granite"])  # quartz missing
    monkeypatch.setattr(cc, "SWIFT", swift_file)
    monkeypatch.setattr(cc, "MANIFEST", manifest_file)
    assert cc.main() == 1
    err = capsys.readouterr().err
    assert "quartz" in err


def test_main_warns_but_does_not_fail_on_unused_manifest_entry(tmp_path, monkeypatch, capsys):
    swift_file = tmp_path / "Codewords.swift"
    swift_file.write_text(SWIFT_FIXTURE)
    manifest_file = tmp_path / "codeword_data.json"
    _write_manifest(manifest_file, ["vesuvius", "granite", "quartz", "unused_word"])
    monkeypatch.setattr(cc, "SWIFT", swift_file)
    monkeypatch.setattr(cc, "MANIFEST", manifest_file)
    assert cc.main() == 0
    out = capsys.readouterr().out
    assert "unused_word" in out
