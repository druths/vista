"""Discovering and describing briefs inside a brief location.

A "briefing" is a named directory in the agent's workspace (Policy Briefs,
Personal Briefs, ...). Briefs are the documents nested beneath it. In
practice a single brief shows up as several files that belong together:

    AI_Policy_Brief-2026-06-15.pdf            the brief
    AI_Policy_Brief-2026-06-15.md             the markdown it was rendered from
    AI_Policy_Brief-2026-06-15.annotated.pdf  Apple Markup written back by Vista

These are collapsed into one Brief so the list reads as one row per briefing
document rather than three near-duplicate filenames.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import PurePosixPath

from . import ark, config
from .ark import ArkClient

ANNOTATED_SUFFIX = ".annotated.pdf"

DOC_EXTENSIONS = {".pdf", ".md", ".markdown", ".txt"}
RENDERED_EXTENSIONS = {".pdf"}

# Directories that never contain briefs worth showing.
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", ".obsidian", "uploads"}

# Dates as they actually appear in brief filenames:
#   Personal_Family_Brief-2026-06-01   daily_brief_2026-06-03   2026-06-09-daily-brief
_DATE_PATTERNS = [
    re.compile(r"(?P<y>\d{4})[-_.](?P<m>\d{1,2})[-_.](?P<d>\d{1,2})"),
    re.compile(r"(?<!\d)(?P<y>\d{4})(?P<m>\d{2})(?P<d>\d{2})(?!\d)"),
]


def extract_date(name: str) -> tuple[date | None, str]:
    """Pull a date out of a filename.

    Returns the date (or None) and the name with the date token removed, so
    the caller can build a title from what's left. File mtime is a poor proxy
    for a brief's date — copying or checking out a brief tree rewrites it —
    so the filename is the primary source and mtime only the fallback.
    """
    for pattern in _DATE_PATTERNS:
        for match in pattern.finditer(name):
            try:
                found = date(
                    int(match.group("y")), int(match.group("m")), int(match.group("d"))
                )
            except ValueError:
                continue  # e.g. a version string like 2026-99-99
            if not (1900 <= found.year <= 2999):
                continue
            remainder = name[: match.start()] + name[match.end() :]
            return found, remainder
    return None, name


def humanize(stem: str) -> str:
    """Turn a filename stem into a readable title."""
    _, remainder = extract_date(stem)
    words = re.sub(r"[_\-]+", " ", remainder)
    words = re.sub(r"\s+", " ", words).strip(" -_.")
    if not words:
        # Nothing but the date in the name — keep it verbatim rather than
        # turning "2026-06-09" into "2026 06 09".
        return stem
    # Leave intentional capitalization (AI_Policy_Brief) alone; only fix
    # all-lowercase names like "daily brief".
    if words.islower():
        words = words.title()
    return words


def split_variant(filename: str) -> tuple[str, str, bool]:
    """Split a filename into (stem, extension, is_annotated)."""
    if filename.lower().endswith(ANNOTATED_SUFFIX):
        return filename[: -len(ANNOTATED_SUFFIX)], ".pdf", True
    path = PurePosixPath(filename)
    return path.stem, path.suffix.lower(), False


@dataclass
class Brief:
    """One briefing document, with every file that represents it."""

    key: str                      # briefing-relative path without extension
    title: str
    folder: str                   # briefing-relative directory, "" at the root
    date: date | None
    mtime: float
    size: int
    pdf_path: str | None = None       # workspace-relative
    text_path: str | None = None      # workspace-relative .md/.txt source
    annotated_path: str | None = None # workspace-relative Apple Markup sidecar
    _dates: list[date] = field(default_factory=list, repr=False)

    @property
    def annotated(self) -> bool:
        return self.annotated_path is not None

    @property
    def effective_date(self) -> datetime:
        """The instant used for ordering. Not for display — see display_date."""
        if self.date:
            return datetime(self.date.year, self.date.month, self.date.day, tzinfo=timezone.utc)
        return datetime.fromtimestamp(self.mtime, tz=timezone.utc)

    @property
    def display_date(self) -> date:
        """The brief's date as a calendar date.

        A date read from a filename is a calendar date, not a moment in time.
        Sending it as an instant (midnight UTC) meant clients west of UTC
        rendered it in local time and showed the previous day — a brief named
        AI-2026-09-08 displayed as 2026-09-07. Calendar dates travel as
        YYYY-MM-DD so no client can shift them across a zone.
        """
        if self.date:
            return self.date
        return datetime.fromtimestamp(self.mtime, tz=timezone.utc).date()

    @property
    def date_source(self) -> str:
        return "filename" if self.date else "mtime"

    def to_json(self) -> dict:
        return {
            "key": self.key,
            "title": self.title,
            "folder": self.folder,
            # A calendar date (YYYY-MM-DD), deliberately not an instant.
            "date": self.display_date.isoformat(),
            "date_source": self.date_source,
            "modified": datetime.fromtimestamp(self.mtime, tz=timezone.utc).isoformat(),
            "size": self.size,
            "annotated": self.annotated,
            "pdf_path": self.pdf_path,
            "text_path": self.text_path,
            "annotated_path": self.annotated_path,
            # What a reader should open by default: the marked-up copy if one
            # exists, else the PDF, else the markdown source.
            "primary_path": self.annotated_path or self.pdf_path or self.text_path,
            "primary_kind": (
                "pdf" if (self.annotated_path or self.pdf_path) else "text"
            ),
        }


async def _walk(
    client: ArkClient, root: str, rel: str, depth: int, out: list[tuple[str, ark.Entry]]
) -> None:
    """Collect files under `root`, recursing breadth-first up to MAX_BRIEF_DEPTH."""
    try:
        entries = await client.list_dir(ark.join(root, rel))
    except ark.NotFound:
        if not rel:
            raise
        return  # a directory vanished mid-walk; not fatal

    subdirs = []
    for entry in entries:
        if entry.name.startswith("."):
            continue
        if entry.is_dir:
            if entry.name not in SKIP_DIRS and depth < config.MAX_BRIEF_DEPTH:
                subdirs.append(entry.name)
        else:
            out.append((rel, entry))

    if subdirs:
        await asyncio.gather(
            *(_walk(client, root, ark.join(rel, name), depth + 1, out) for name in subdirs)
        )


async def list_briefs(client: ArkClient, root: str) -> list[Brief]:
    """List every brief nested beneath a brief location."""
    root = ark.normalize_path(root)
    found: list[tuple[str, ark.Entry]] = []
    await _walk(client, root, "", 1, found)

    briefs: dict[str, Brief] = {}
    for folder, entry in found:
        stem, ext, is_annotated = split_variant(entry.name)
        if ext not in DOC_EXTENSIONS:
            continue

        key = ark.join(folder, stem) or stem
        brief = briefs.get(key)
        if brief is None:
            file_date, _ = extract_date(stem)
            brief = Brief(
                key=key,
                title=humanize(stem),
                folder=folder,
                date=file_date,
                mtime=entry.mtime,
                size=0,
            )
            briefs[key] = brief

        workspace_path = ark.join(root, folder, entry.name)
        if is_annotated:
            brief.annotated_path = workspace_path
        elif ext in RENDERED_EXTENSIONS:
            brief.pdf_path = workspace_path
            brief.size = entry.size
        else:
            brief.text_path = workspace_path
            if brief.pdf_path is None:
                brief.size = entry.size

        # Newest mtime across the group; only used when the filename has no date.
        brief.mtime = max(brief.mtime, entry.mtime)

    return sorted(
        briefs.values(), key=lambda b: (b.effective_date, b.title), reverse=True
    )


def sort_briefs(briefs: list[Brief], sort: str, order: str) -> list[Brief]:
    """Sort briefs by date or name. Date order defaults to newest first."""
    if sort == "name":
        key = lambda b: (b.title.lower(), b.effective_date)  # noqa: E731
        reverse = order == "desc"
    else:
        key = lambda b: (b.effective_date, b.title.lower())  # noqa: E731
        reverse = order != "asc"
    return sorted(briefs, key=key, reverse=reverse)


def annotated_path_for(pdf_path: str) -> str:
    """Where the Apple Markup sidecar for a brief PDF belongs.

    Non-destructive by design: the original brief is never written to, so a
    sync bug can't destroy the source document.
    """
    path = PurePosixPath(pdf_path)
    if pdf_path.lower().endswith(ANNOTATED_SUFFIX):
        return pdf_path
    return str(path.with_name(path.stem + ANNOTATED_SUFFIX))
