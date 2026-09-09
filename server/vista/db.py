"""SQLite storage for Vista's own state: users, their Ark connection, and
their configured brief locations.

Vista stores no document content. Briefs and notes live in the Ark agent's
workspace and are read through it on every request.
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    email          TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash  TEXT NOT NULL,
    display_name   TEXT NOT NULL DEFAULT '',
    created_at     TEXT NOT NULL,
    ark_base_url   TEXT NOT NULL DEFAULT '',
    ark_token_enc  TEXT NOT NULL DEFAULT '',
    ark_agent      TEXT NOT NULL DEFAULT '',
    notes_dir      TEXT NOT NULL DEFAULT 'notes'
);

CREATE TABLE IF NOT EXISTS briefings (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    path        TEXT NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_briefings_user ON briefings(user_id);
"""


def connect() -> sqlite3.Connection:
    config.HOME.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(config.DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def init(conn: sqlite3.Connection | None = None) -> None:
    own = conn is None
    conn = conn or connect()
    try:
        conn.executescript(SCHEMA)
        conn.commit()
    finally:
        if own:
            conn.close()


@contextmanager
def session() -> Iterator[sqlite3.Connection]:
    conn = connect()
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


# --- users -----------------------------------------------------------------


def create_user(
    conn: sqlite3.Connection,
    *,
    email: str,
    password_hash: str,
    display_name: str = "",
) -> int:
    cur = conn.execute(
        "INSERT INTO users (email, password_hash, display_name, created_at) "
        "VALUES (?, ?, ?, ?)",
        (email.strip(), password_hash, display_name, now()),
    )
    return int(cur.lastrowid)


def get_user_by_email(conn: sqlite3.Connection, email: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM users WHERE email = ?", (email.strip(),)
    ).fetchone()


def get_user(conn: sqlite3.Connection, user_id: int) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()


def list_users(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM users ORDER BY id").fetchall()


def set_ark_connection(
    conn: sqlite3.Connection,
    user_id: int,
    *,
    base_url: str,
    token_enc: str,
    agent: str,
    notes_dir: str,
) -> None:
    conn.execute(
        "UPDATE users SET ark_base_url = ?, ark_token_enc = ?, ark_agent = ?, "
        "notes_dir = ? WHERE id = ?",
        (base_url.rstrip("/"), token_enc, agent, notes_dir.strip("/"), user_id),
    )


def set_ark_endpoint(
    conn: sqlite3.Connection, user_id: int, *, base_url: str, agent: str
) -> None:
    """Update where an account points without touching its stored token."""
    conn.execute(
        "UPDATE users SET ark_base_url = ?, ark_agent = ? WHERE id = ?",
        (base_url.rstrip("/"), agent.strip(), user_id),
    )


def set_ark_token(conn: sqlite3.Connection, user_id: int, token_enc: str) -> None:
    conn.execute(
        "UPDATE users SET ark_token_enc = ? WHERE id = ?", (token_enc, user_id)
    )


def set_notes_dir(conn: sqlite3.Connection, user_id: int, notes_dir: str) -> None:
    conn.execute(
        "UPDATE users SET notes_dir = ? WHERE id = ?", (notes_dir.strip("/"), user_id)
    )


def set_password(conn: sqlite3.Connection, user_id: int, password_hash: str) -> None:
    conn.execute(
        "UPDATE users SET password_hash = ? WHERE id = ?", (password_hash, user_id)
    )


def delete_user(conn: sqlite3.Connection, user_id: int) -> None:
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))


# --- briefings -------------------------------------------------------------


def list_briefings(conn: sqlite3.Connection, user_id: int) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT * FROM briefings WHERE user_id = ? ORDER BY sort_order, id",
        (user_id,),
    ).fetchall()


def get_briefing(
    conn: sqlite3.Connection, user_id: int, briefing_id: int
) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM briefings WHERE id = ? AND user_id = ?", (briefing_id, user_id)
    ).fetchone()


def add_briefing(
    conn: sqlite3.Connection, user_id: int, *, name: str, path: str
) -> int:
    order = conn.execute(
        "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM briefings WHERE user_id = ?",
        (user_id,),
    ).fetchone()[0]
    cur = conn.execute(
        "INSERT INTO briefings (user_id, name, path, sort_order) VALUES (?, ?, ?, ?)",
        (user_id, name.strip(), path.strip("/"), order),
    )
    return int(cur.lastrowid)


def update_briefing(
    conn: sqlite3.Connection, user_id: int, briefing_id: int, *, name: str, path: str
) -> bool:
    cur = conn.execute(
        "UPDATE briefings SET name = ?, path = ? WHERE id = ? AND user_id = ?",
        (name.strip(), path.strip("/"), briefing_id, user_id),
    )
    return cur.rowcount > 0


def reorder_briefings(
    conn: sqlite3.Connection, user_id: int, ordered_ids: list[int]
) -> None:
    """Apply an explicit order. Ids not owned by this user are ignored."""
    for position, briefing_id in enumerate(ordered_ids):
        conn.execute(
            "UPDATE briefings SET sort_order = ? WHERE id = ? AND user_id = ?",
            (position, briefing_id, user_id),
        )


def remove_briefing(conn: sqlite3.Connection, user_id: int, briefing_id: int) -> bool:
    cur = conn.execute(
        "DELETE FROM briefings WHERE id = ? AND user_id = ?", (briefing_id, user_id)
    )
    return cur.rowcount > 0
