"""Integration tests against a real Ark server.

These verify the assumptions Vista makes about Ark that a mock would simply
agree with: that listings are one level deep with millisecond mtimes, that
traversal is refused, and — critically for reading briefs — that file
downloads honour Range requests.
"""

from __future__ import annotations

import pytest

from vista import ark, briefs as briefs_mod, notes as notes_mod
from vista.ark import ArkClient

from conftest import requires_ark

pytestmark = requires_ark


async def _cleanup(client: ArkClient, path: str) -> None:
    try:
        await client.delete(path)
    except ark.ArkError:
        pass


async def test_write_read_roundtrip(ark_client: ArkClient, scratch: str) -> None:
    path = f"{scratch}/hello.md"
    try:
        await ark_client.write_file(path, b"# hello\n")
        assert await ark_client.read_file(path) == b"# hello\n"
        assert await ark_client.exists(path)
    finally:
        await _cleanup(ark_client, scratch)


async def test_missing_file_raises_not_found(ark_client: ArkClient, scratch: str) -> None:
    with pytest.raises(ark.NotFound):
        await ark_client.read_file(f"{scratch}/definitely-absent.md")
    assert not await ark_client.exists(f"{scratch}/definitely-absent.md")


async def test_listing_reports_millisecond_mtimes(ark_client: ArkClient, scratch: str) -> None:
    """Vista divides listing mtimes by 1000; confirm Ark really sends ms."""
    import time

    try:
        await ark_client.write_file(f"{scratch}/a.md", b"a")
        entries = await ark_client.list_dir(scratch)
        entry = next(e for e in entries if e.name == "a.md")
        # If Ark sent seconds, .mtime would land in 1970.
        assert abs(entry.mtime - time.time()) < 300, f"mtime looks wrong: {entry.mtime}"
    finally:
        await _cleanup(ark_client, scratch)


async def test_range_requests_are_honoured(ark_client: ArkClient, scratch: str) -> None:
    """PDF viewers page into a brief with Range; Vista passes it through."""
    path = f"{scratch}/data.bin"
    payload = bytes(range(256)) * 40  # 10240 bytes
    try:
        await ark_client.write_file(path, payload)

        status, headers, body = await ark_client.stream_file(path, "bytes=100-199")
        chunks = b"".join([c async for c in body])

        assert status == 206, f"expected partial content, got {status}"
        assert chunks == payload[100:200]
        assert headers.get("content-range") == f"bytes 100-199/{len(payload)}"
    finally:
        await _cleanup(ark_client, scratch)


async def test_full_download_when_no_range(ark_client: ArkClient, scratch: str) -> None:
    path = f"{scratch}/full.bin"
    payload = b"x" * 5000
    try:
        await ark_client.write_file(path, payload)
        status, _, body = await ark_client.stream_file(path, None)
        chunks = b"".join([c async for c in body])
        assert status == 200
        assert chunks == payload
    finally:
        await _cleanup(ark_client, scratch)


async def test_traversal_is_refused_by_ark(ark_client: ArkClient) -> None:
    """Belt and braces: even if Vista's own check were bypassed."""
    with pytest.raises(ark.ArkError):
        await ark_client.read_file("../../etc/passwd")


async def test_rename_moves_a_file(ark_client: ArkClient, scratch: str) -> None:
    try:
        await ark_client.write_file(f"{scratch}/before.md", b"content")
        await ark_client.rename(f"{scratch}/before.md", f"{scratch}/after.md")
        assert await ark_client.read_file(f"{scratch}/after.md") == b"content"
        assert not await ark_client.exists(f"{scratch}/before.md")
    finally:
        await _cleanup(ark_client, scratch)


async def test_briefs_are_discovered_and_variants_collapsed(
    ark_client: ArkClient, scratch: str
) -> None:
    """The whole point of the brief list: one row per document, not per file."""
    root = f"{scratch}/briefs"
    try:
        await ark_client.write_file(f"{root}/AI_Policy_Brief-2026-06-15.pdf", b"%PDF-1.4 fake")
        await ark_client.write_file(f"{root}/AI_Policy_Brief-2026-06-15.md", b"# source")
        await ark_client.write_file(f"{root}/AI_Policy_Brief-2026-06-01.pdf", b"%PDF-1.4 fake")
        # A brief nested one level deeper must still be found.
        await ark_client.write_file(f"{root}/archive/daily_brief_2025-01-02.pdf", b"%PDF-1.4")
        # Non-brief files must be ignored.
        await ark_client.write_file(f"{root}/notes.json", b"{}")

        found = await briefs_mod.list_briefs(ark_client, root)
        by_title = {(b.title, b.effective_date.date().isoformat()): b for b in found}

        assert len(found) == 3, [b.key for b in found]
        newest = found[0]
        assert newest.title == "AI Policy Brief"
        assert newest.effective_date.date().isoformat() == "2026-06-15"
        # The .pdf and .md collapsed into one brief carrying both paths.
        assert newest.pdf_path.endswith("AI_Policy_Brief-2026-06-15.pdf")
        assert newest.text_path.endswith("AI_Policy_Brief-2026-06-15.md")
        assert not newest.annotated

        nested = by_title[("Daily Brief", "2025-01-02")]
        assert nested.folder == "archive"
    finally:
        await _cleanup(ark_client, scratch)


async def test_annotated_sidecar_joins_its_brief(ark_client: ArkClient, scratch: str) -> None:
    root = f"{scratch}/briefs"
    original = f"{root}/Brief-2026-06-15.pdf"
    try:
        await ark_client.write_file(original, b"%PDF-1.4 original")
        await ark_client.write_file(
            briefs_mod.annotated_path_for(original), b"%PDF-1.4 marked up"
        )

        found = await briefs_mod.list_briefs(ark_client, root)

        assert len(found) == 1, "markup must not appear as a separate brief"
        brief = found[0]
        assert brief.annotated
        assert brief.to_json()["primary_path"] == briefs_mod.annotated_path_for(original)
        # The original is untouched and still reachable.
        assert await ark_client.read_file(original) == b"%PDF-1.4 original"
    finally:
        await _cleanup(ark_client, scratch)


async def test_notes_listing_and_preview(ark_client: ArkClient, scratch: str) -> None:
    notes_dir = f"{scratch}/notes"
    try:
        await ark_client.write_file(
            f"{notes_dir}/Standup.md", b"# Standup\n\n- shipped the thing\n"
        )
        await ark_client.write_file(f"{notes_dir}/Ideas.txt", b"raw idea\n")
        await ark_client.write_file(f"{notes_dir}/ignore.pdf", b"%PDF")

        found = await notes_mod.list_notes(ark_client, notes_dir, with_preview=True)
        names = {n.name for n in found}

        assert names == {"Standup.md", "Ideas.txt"}, "only note files belong in the list"
        standup = next(n for n in found if n.name == "Standup.md")
        assert standup.title == "Standup"
        # Markdown chrome is stripped, and the leading "# Standup" heading is
        # dropped because it only restates the title shown beside it.
        assert standup.preview == "shipped the thing"
    finally:
        await _cleanup(ark_client, scratch)


async def test_list_notes_creates_a_missing_directory(
    ark_client: ArkClient, scratch: str
) -> None:
    """A fresh agent has no notes dir; that must not be an error the user sees."""
    notes_dir = f"{scratch}/brand-new-notes"
    try:
        assert await notes_mod.list_notes(ark_client, notes_dir) == []
        assert await ark_client.exists(notes_dir)
    finally:
        await _cleanup(ark_client, scratch)


async def test_unique_name_suffixes_on_collision(ark_client: ArkClient, scratch: str) -> None:
    notes_dir = f"{scratch}/notes"
    try:
        first = await notes_mod.unique_name(ark_client, notes_dir, "Meeting")
        await ark_client.write_file(f"{notes_dir}/{first}", b"one")
        second = await notes_mod.unique_name(ark_client, notes_dir, "Meeting")

        assert first == "Meeting.md"
        assert second == "Meeting-2.md"
    finally:
        await _cleanup(ark_client, scratch)
