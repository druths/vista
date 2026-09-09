"""Path handling — the boundary that keeps one user's request inside the
directory it is supposed to touch."""

from __future__ import annotations

import pytest

from vista import ark
from vista.notes import NoteError, resolve_name, slugify


@pytest.mark.parametrize(
    "bad",
    [
        "../../../etc/passwd",
        "/etc/passwd",
        "notes/../../secrets",
        "..",
    ],
)
def test_normalize_path_rejects_traversal(bad: str) -> None:
    with pytest.raises(ark.ArkError):
        ark.normalize_path(bad)


def test_normalize_path_cleans_harmless_input() -> None:
    assert ark.normalize_path("briefs/policy/") == "briefs/policy"
    assert ark.normalize_path("briefs//policy") == "briefs/policy"
    assert ark.normalize_path("./briefs/./policy") == "briefs/policy"
    assert ark.normalize_path("") == ""


def test_join_drops_empty_segments() -> None:
    assert ark.join("briefs", "", "policy") == "briefs/policy"
    assert ark.join("", "notes") == "notes"


@pytest.mark.parametrize("bad", ["../evil.md", "sub/dir.md", "", ".", "..", "a\\b.md"])
def test_note_names_must_be_flat_filenames(bad: str) -> None:
    with pytest.raises(NoteError):
        resolve_name(bad, "notes")


def test_note_name_gets_default_extension() -> None:
    assert resolve_name("Standup", "notes") == "notes/Standup.md"
    assert resolve_name("Standup.md", "notes") == "notes/Standup.md"
    assert resolve_name("todo.txt", "notes") == "notes/todo.txt"


def test_slugify_strips_path_and_control_characters() -> None:
    assert "/" not in slugify("a/b")
    assert "\\" not in slugify("a\\b")
    assert slugify("  Meeting: notes?  ") == "Meeting notes"


def test_slugify_falls_back_when_title_is_empty() -> None:
    """An untitled note still needs a filename."""
    assert slugify("   ").startswith("Note ")
