"""Pure-logic tests for how filenames become briefs. No Ark required."""

from __future__ import annotations

from datetime import date

import pytest

from vista.briefs import (
    annotated_path_for,
    extract_date,
    humanize,
    split_variant,
)


@pytest.mark.parametrize(
    "filename,expected",
    [
        # The three date conventions that appear in real brief output dirs.
        ("Personal_Family_Brief-2026-06-01", date(2026, 6, 1)),
        ("daily_brief_2026-06-03", date(2026, 6, 3)),
        ("2026-06-09-daily-brief", date(2026, 6, 9)),
        ("AI_Policy_Brief-2026-05-28", date(2026, 5, 28)),
        ("notes_20260612", date(2026, 6, 12)),
        ("no date here", None),
    ],
)
def test_extract_date(filename: str, expected: date | None) -> None:
    assert extract_date(filename)[0] == expected


def test_extract_date_rejects_impossible_dates() -> None:
    """A version-like token must not be mistaken for a date."""
    assert extract_date("build-2026-99-99")[0] is None
    assert extract_date("v1-2026-13-01")[0] is None


def test_extract_date_ignores_long_digit_runs() -> None:
    """An 8-digit date must be a standalone token, not part of a longer id."""
    assert extract_date("id_1234202606129999")[0] is None


@pytest.mark.parametrize(
    "stem,title",
    [
        ("Personal_Family_Brief-2026-06-01", "Personal Family Brief"),
        ("daily_brief_2026-06-03", "Daily Brief"),
        ("2026-06-09-daily-brief", "Daily Brief"),
        ("AI_Policy_Brief-2026-05-28", "AI Policy Brief"),
    ],
)
def test_humanize(stem: str, title: str) -> None:
    assert humanize(stem) == title


def test_humanize_survives_a_date_only_name() -> None:
    """A brief named only by its date still needs some title."""
    assert humanize("2026-06-09") == "2026-06-09"


def test_split_variant_recognizes_annotated_sidecar() -> None:
    assert split_variant("Brief-2026-06-01.annotated.pdf") == (
        "Brief-2026-06-01",
        ".pdf",
        True,
    )
    assert split_variant("Brief-2026-06-01.pdf") == ("Brief-2026-06-01", ".pdf", False)
    assert split_variant("Brief-2026-06-01.md") == ("Brief-2026-06-01", ".md", False)


def test_annotated_path_is_a_sidecar_and_idempotent() -> None:
    """Saving markup must never overwrite the original brief."""
    original = "briefs/policy/Brief-2026-06-01.pdf"
    sidecar = annotated_path_for(original)
    assert sidecar == "briefs/policy/Brief-2026-06-01.annotated.pdf"
    assert sidecar != original
    # Re-saving markup on an already-annotated file stays on the same sidecar
    # instead of producing Brief.annotated.annotated.pdf.
    assert annotated_path_for(sidecar) == sidecar


def test_preview_strips_markdown_chrome() -> None:
    from vista.notes import preview_of

    text = "# Heading\n\n> quoted\n\n- **bold** point\n"
    assert preview_of(text) == "Heading quoted bold point"


def test_preview_drops_a_heading_that_only_repeats_the_title() -> None:
    """The title is already shown beside the preview in the notes list."""
    from vista.notes import preview_of

    assert preview_of("# Standup\n\nshipped it\n", "Standup") == "shipped it"
    # A heading that says something new is kept.
    assert preview_of("# Monday\n\nshipped it\n", "Standup") == "Monday shipped it"


def test_preview_of_an_empty_note_is_empty() -> None:
    from vista.notes import preview_of

    assert preview_of("") == ""
    assert preview_of("# Standup\n", "Standup") == ""


def test_display_date_is_a_calendar_date_not_an_instant() -> None:
    """A date read from a filename must not travel as a timestamp.

    Sent as midnight UTC, every client west of UTC rendered the previous day:
    a brief named AI-2026-09-08 showed as 2026-09-07.
    """
    from vista.briefs import Brief

    brief = Brief(key="k", title="AI", folder="", date=date(2026, 9, 8),
                  mtime=0.0, size=1)
    payload = brief.to_json()

    assert payload["date"] == "2026-09-08"
    assert "T" not in payload["date"], "a calendar date carries no time or zone"
    assert payload["date_source"] == "filename"


def test_display_date_falls_back_to_the_file_time() -> None:
    from datetime import datetime, timezone

    from vista.briefs import Brief

    stamp = datetime(2026, 3, 4, 15, 30, tzinfo=timezone.utc).timestamp()
    brief = Brief(key="k", title="Untitled", folder="", date=None,
                  mtime=stamp, size=1)
    payload = brief.to_json()

    assert payload["date"] == "2026-03-04"
    assert payload["date_source"] == "mtime"
