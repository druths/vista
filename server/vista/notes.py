"""Notes: a flat directory of markdown/text files in the agent's workspace.

Deliberately thin. A note is a file; its name is its identity; its title is
the filename stem. There is no database, no index, and no Vista-side metadata
— so a note written here is immediately a plain file the agent can read, and
a file the agent writes is immediately a note.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import PurePosixPath

from . import ark
from .ark import ArkClient

NOTE_EXTENSIONS = {".md", ".markdown", ".txt"}
DEFAULT_EXTENSION = ".md"

# How many notes to pull content for when building previews.
PREVIEW_LIMIT = 60
PREVIEW_CHARS = 200
_PREVIEW_CONCURRENCY = 8


class NoteError(RuntimeError):
    pass


def slugify(title: str) -> str:
    """Turn a user-supplied title into a safe, readable filename stem."""
    cleaned = title.strip()
    # Drop path separators and characters that are awkward in filenames.
    cleaned = re.sub(r"[/\\:*?\"<>|\x00-\x1f]", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    if not cleaned:
        cleaned = datetime.now().strftime("Note %Y-%m-%d %H%M%S")
    return cleaned[:120]


def is_note(filename: str) -> bool:
    return PurePosixPath(filename).suffix.lower() in NOTE_EXTENSIONS


def preview_of(text: str, title: str = "") -> str:
    """First meaningful line(s) of a note, with markdown chrome stripped.

    A note usually opens with a heading that repeats its filename, which would
    make every preview start by restating the title next to it. Drop that
    leading line when it does.
    """
    lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        line = re.sub(r"^#{1,6}\s*", "", line)      # headings
        line = re.sub(r"^[-*+]\s+", "", line)        # bullets
        line = re.sub(r"^>\s*", "", line)            # quotes
        line = re.sub(r"[*_`]", "", line)            # emphasis
        if line:
            if not lines and title and line.strip().lower() == title.strip().lower():
                continue
            lines.append(line)
        if sum(len(x) for x in lines) > PREVIEW_CHARS:
            break
    joined = " ".join(lines)
    return joined[:PREVIEW_CHARS].rstrip() + ("…" if len(joined) > PREVIEW_CHARS else "")


@dataclass
class Note:
    name: str            # filename, e.g. "Standup 2026-09-08.md"
    path: str            # workspace-relative
    size: int
    mtime: float
    preview: str = ""

    @property
    def title(self) -> str:
        return PurePosixPath(self.name).stem

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "title": self.title,
            "path": self.path,
            "size": self.size,
            "modified": datetime.fromtimestamp(self.mtime, tz=timezone.utc).isoformat(),
            "preview": self.preview,
        }


async def list_notes(
    client: ArkClient, notes_dir: str, *, with_preview: bool = False
) -> list[Note]:
    """List notes, newest first. Creates the notes directory if absent."""
    notes_dir = ark.normalize_path(notes_dir)
    try:
        entries = await client.list_dir(notes_dir)
    except ark.NotFound:
        # First run against a fresh agent: make the directory rather than
        # surfacing a 404 the user can do nothing about.
        await client.mkdir(notes_dir)
        return []

    notes = [
        Note(
            name=e.name,
            path=ark.join(notes_dir, e.name),
            size=e.size,
            mtime=e.mtime,
        )
        for e in entries
        if not e.is_dir and not e.name.startswith(".") and is_note(e.name)
    ]
    notes.sort(key=lambda n: n.mtime, reverse=True)

    if with_preview and notes:
        await _attach_previews(client, notes[:PREVIEW_LIMIT])
    return notes


async def _attach_previews(client: ArkClient, notes: list[Note]) -> None:
    semaphore = asyncio.Semaphore(_PREVIEW_CONCURRENCY)

    async def load(note: Note) -> None:
        async with semaphore:
            try:
                raw = await client.read_file(note.path)
                note.preview = preview_of(
                    raw.decode("utf-8", errors="replace"), note.title
                )
            except ark.ArkError:
                note.preview = ""  # a preview is never worth failing the list over

    await asyncio.gather(*(load(n) for n in notes))


def sort_notes(notes: list[Note], sort: str, order: str) -> list[Note]:
    if sort == "name":
        key = lambda n: n.title.lower()  # noqa: E731
        reverse = order == "desc"
    else:
        key = lambda n: n.mtime  # noqa: E731
        reverse = order != "asc"
    return sorted(notes, key=key, reverse=reverse)


def resolve_name(name: str, notes_dir: str) -> str:
    """Validate a note filename and return its workspace-relative path.

    Notes are flat: a name is a filename, never a path. This rejects any
    attempt to reach outside the notes directory.
    """
    candidate = (name or "").strip()
    if not candidate or "/" in candidate or "\\" in candidate or candidate in (".", ".."):
        raise NoteError(f"invalid note name: {name!r}")
    if not is_note(candidate):
        candidate += DEFAULT_EXTENSION
    return ark.join(ark.normalize_path(notes_dir), candidate)


async def unique_name(client: ArkClient, notes_dir: str, title: str) -> str:
    """Pick a filename for a new note, suffixing on collision.

    Mirrors Ark's own upload-collision convention: note.md, note-2.md, ...
    """
    stem = slugify(title)
    notes_dir = ark.normalize_path(notes_dir)
    candidate = f"{stem}{DEFAULT_EXTENSION}"
    index = 2
    while await client.exists(ark.join(notes_dir, candidate)):
        candidate = f"{stem}-{index}{DEFAULT_EXTENSION}"
        index += 1
        if index > 500:
            raise NoteError("could not find an unused note name")
    return candidate
