"""The golden known-items pair: a source text and the known-items file it
makes, built from the source's Deviations and Review headings byte for byte
by the Known items helpers - the pin of the known-items file's format
(ADR-0067) since the bash helpers that built it from the same two files were
deleted."""
from __future__ import annotations

from pathlib import Path

from orch.known_items import known_items_write, section_entries_append

GOLDEN = Path(__file__).resolve().parent / "known_items"


def test_the_golden_source_builds_the_golden_known_items_file_byte_for_byte(tmp_path):
    source = (GOLDEN / "source.md").read_text()

    known_items_write(str(tmp_path / "known.md"),
                      section_entries_append(source, "## Deviations"),
                      section_entries_append(source, "## Review", "declined"))

    assert (tmp_path / "known.md").read_bytes() == (GOLDEN / "expected.md").read_bytes()
