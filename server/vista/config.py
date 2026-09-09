"""Process configuration, read from the environment at import time.

Vista keeps its own state (users, per-user Ark credentials) in a SQLite
database under VISTA_HOME. Everything else lives on the Ark server.
"""

from __future__ import annotations

import os
from pathlib import Path


def _home() -> Path:
    return Path(os.environ.get("VISTA_HOME", "~/.vista")).expanduser()


HOME = _home()
DB_PATH = HOME / "vista.db"

# Signs session JWTs and, via HKDF, derives the key that encrypts stored Ark
# tokens. Rotating it invalidates sessions *and* makes stored Ark tokens
# unreadable, so treat it as durable secret material.
SECRET_KEY = os.environ.get("VISTA_SECRET_KEY", "")

# Browser origins allowed to call the API. Ark itself sends no CORS headers,
# which is a large part of why this server exists.
CORS_ORIGINS = [
    o.strip()
    for o in os.environ.get(
        "VISTA_CORS_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173"
    ).split(",")
    if o.strip()
]

SESSION_TTL_HOURS = int(os.environ.get("VISTA_SESSION_TTL_HOURS", "720"))

# Upper bound on how deep a brief location is walked. Brief locations point at
# a directory and briefs may be "nested beneath" it, but Ark lists one level
# per request, so depth costs round trips.
MAX_BRIEF_DEPTH = int(os.environ.get("VISTA_MAX_BRIEF_DEPTH", "4"))

HTTP_TIMEOUT = float(os.environ.get("VISTA_HTTP_TIMEOUT", "30"))


class ConfigError(RuntimeError):
    pass


def require_secret_key() -> str:
    if not SECRET_KEY:
        raise ConfigError(
            "VISTA_SECRET_KEY is not set. Generate one with:\n"
            "  python -c \"import secrets; print(secrets.token_hex(32))\""
        )
    return SECRET_KEY
