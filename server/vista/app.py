"""Vista's HTTP API.

Vista sits between its clients (web, iOS) and an Ark server. It exists for
three reasons Ark can't cover on its own:

  1. Ark has no per-user identity — one bearer token grants full read/write
     to every agent workspace. That token stays here, encrypted at rest, and
     is never handed to a client.
  2. Ark sends no CORS headers, so a browser cannot call it directly.
  3. Briefs and notes are *conventions* over a directory tree. The shaping
     lives here so every client sees the same model.
"""

from __future__ import annotations

import sqlite3
from contextlib import asynccontextmanager
from pathlib import PurePosixPath
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from . import ark, briefs as briefs_mod, config, db, notes as notes_mod, security
from .ark import ArkClient

@asynccontextmanager
async def lifespan(_: FastAPI):
    config.require_secret_key()
    db.init()
    yield


app = FastAPI(
    title="Vista",
    version="0.1.0",
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    # A PDF viewer needs these to page into a brief with Range requests.
    expose_headers=["Content-Range", "Accept-Ranges", "Content-Length", "Content-Disposition"],
)


@app.exception_handler(ark.ArkError)
async def _ark_error_handler(request: Request, exc: ark.ArkError) -> JSONResponse:
    """Surface upstream Ark failures as something a client can act on.

    A 401 from Ark means *Vista's* stored token is wrong, not that the caller
    is unauthenticated — reporting it as 502 keeps clients from bouncing the
    user to a login screen that cannot fix it.
    """
    if isinstance(exc, ark.NotFound):
        status = 404
    elif exc.status in (400, 409, 413):
        status = exc.status
    else:
        status = 502
    return JSONResponse({"detail": str(exc), "source": "ark"}, status_code=status)


# --- request/response models ----------------------------------------------


class LoginRequest(BaseModel):
    email: str
    password: str


class NoteCreate(BaseModel):
    title: str = Field(default="", max_length=200)
    content: str = ""


class NoteUpdate(BaseModel):
    content: str


class NoteRename(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class ArkConnectionUpdate(BaseModel):
    base_url: str = Field(min_length=1, max_length=500)
    agent: str = Field(min_length=1, max_length=200)
    # Omitted or blank means "keep the token already stored". The token is
    # never sent back to a client, so a settings form has nothing to re-submit.
    token: str | None = None


class NotesDirUpdate(BaseModel):
    notes_dir: str = Field(min_length=1, max_length=500)


class BriefingInput(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    path: str = Field(min_length=1, max_length=500)


class BriefingOrder(BaseModel):
    ids: list[int]


# --- auth ------------------------------------------------------------------


class Principal:
    """An authenticated user plus a ready-to-use client for their Ark server."""

    def __init__(self, row: sqlite3.Row):
        self.row = row
        self.id = int(row["id"])
        self.email = row["email"]
        self.notes_dir = row["notes_dir"] or "notes"

    @property
    def configured(self) -> bool:
        return bool(self.row["ark_base_url"] and self.row["ark_token_enc"] and self.row["ark_agent"])

    def client(self) -> ArkClient:
        if not self.configured:
            raise HTTPException(
                409,
                "This account has no Ark server configured. "
                "Run: python -m vista connect <email> --url ... --token ... --agent ...",
            )
        try:
            token = security.decrypt_secret(self.row["ark_token_enc"])
        except ValueError as exc:
            raise HTTPException(500, str(exc)) from exc
        return ArkClient(self.row["ark_base_url"], token, self.row["ark_agent"])


def current_user(
    authorization: Annotated[str | None, Header()] = None,
) -> Principal:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    claims = security.read_session(authorization.split(" ", 1)[1].strip())
    if not claims:
        raise HTTPException(401, "invalid or expired session")
    with db.session() as conn:
        row = db.get_user(conn, int(claims["sub"]))
    if row is None:
        raise HTTPException(401, "user no longer exists")
    return Principal(row)


User = Annotated[Principal, Depends(current_user)]


@app.post("/api/auth/login")
def login(body: LoginRequest) -> dict[str, Any]:
    with db.session() as conn:
        row = db.get_user_by_email(conn, body.email)
    # Compare against a dummy hash when the user is unknown so a missing
    # account and a wrong password take the same amount of time.
    stored = row["password_hash"] if row else security.hash_password("__no_such_user__")
    if not security.verify_password(body.password, stored) or row is None:
        raise HTTPException(401, "incorrect email or password")

    token, expires = security.issue_session(int(row["id"]), row["email"])
    return {
        "token": token,
        "expires": expires.isoformat(),
        "user": _user_json(Principal(row)),
    }


def _user_json(user: Principal) -> dict[str, Any]:
    """The one representation of a user.

    Login and /api/me must return the same shape: a client that models "user"
    once should be able to decode it from either. They diverged before —
    briefings appeared only on /api/me — and a strictly-typed client failed to
    decode a login response over it.
    """
    with db.session() as conn:
        briefings = db.list_briefings(conn, user.id)
    return {
        "id": user.id,
        "email": user.email,
        "display_name": user.row["display_name"] or user.email.split("@")[0],
        "configured": user.configured,
        "ark_agent": user.row["ark_agent"] or None,
        "notes_dir": user.notes_dir,
        "briefings": [
            {"id": b["id"], "name": b["name"], "path": b["path"]} for b in briefings
        ],
    }


@app.get("/api/me")
def me(user: User) -> dict[str, Any]:
    return _user_json(user)


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok", "version": app.version}


@app.get("/api/ark/status")
async def ark_status(user: User) -> dict[str, Any]:
    """Confirm the stored Ark credentials actually work."""
    client = user.client()
    try:
        await client.list_dir("")
    except ark.ArkError as exc:
        return {"connected": False, "detail": str(exc), "agent": client.agent}
    return {"connected": True, "agent": client.agent, "base_url": client.base_url}


# --- settings --------------------------------------------------------------


def _clean_workspace_path(value: str, label: str) -> str:
    """Validate a user-supplied workspace path from the settings screen."""
    try:
        cleaned = ark.normalize_path(value)
    except ark.ArkError as exc:
        raise HTTPException(400, f"{label}: {exc}") from exc
    if not cleaned:
        raise HTTPException(400, f"{label} cannot be the workspace root")
    return cleaned


@app.get("/api/settings")
def get_settings(user: User) -> dict[str, Any]:
    """Everything the settings screen needs — never including the Ark token."""
    with db.session() as conn:
        briefings = db.list_briefings(conn, user.id)
    return {
        "ark": {
            "base_url": user.row["ark_base_url"] or "",
            "agent": user.row["ark_agent"] or "",
            # The token is write-only: the client is told whether one exists,
            # not what it is.
            "token_set": bool(user.row["ark_token_enc"]),
        },
        "notes_dir": user.notes_dir,
        "briefings": [
            {"id": b["id"], "name": b["name"], "path": b["path"]} for b in briefings
        ],
    }


async def _probe(base_url: str, token: str, agent: str) -> dict[str, Any]:
    """Check that a set of Ark credentials actually works."""
    try:
        await ArkClient(base_url, token, agent).list_dir("")
    except ark.ArkError as exc:
        return {"connected": False, "detail": str(exc)}
    return {"connected": True, "detail": f"Reached agent “{agent}”."}


@app.post("/api/settings/ark/test")
async def test_ark_connection(user: User, body: ArkConnectionUpdate) -> dict[str, Any]:
    """Try a connection without saving it, so a typo is caught before it
    replaces a working configuration."""
    token = body.token or ""
    if not token:
        if not user.row["ark_token_enc"]:
            raise HTTPException(400, "no token stored yet — enter one to test")
        token = security.decrypt_secret(user.row["ark_token_enc"])
    return await _probe(body.base_url.rstrip("/"), token, body.agent.strip())


@app.put("/api/settings/ark")
async def update_ark_connection(user: User, body: ArkConnectionUpdate) -> dict[str, Any]:
    base_url = body.base_url.rstrip("/")
    agent = body.agent.strip()
    if not base_url.startswith(("http://", "https://")):
        raise HTTPException(400, "the Ark URL must start with http:// or https://")

    with db.session() as conn:
        db.set_ark_endpoint(conn, user.id, base_url=base_url, agent=agent)
        if body.token:
            db.set_ark_token(conn, user.id, security.encrypt_secret(body.token))

    # Report whether the new settings actually work, but don't refuse to save
    # them — a server that is temporarily down shouldn't block configuration.
    token = body.token or (
        security.decrypt_secret(user.row["ark_token_enc"])
        if user.row["ark_token_enc"]
        else ""
    )
    status = (
        await _probe(base_url, token, agent)
        if token
        else {"connected": False, "detail": "no token stored"}
    )
    return {"ok": True, **status}


@app.put("/api/settings/notes")
def update_notes_dir(user: User, body: NotesDirUpdate) -> dict[str, Any]:
    notes_dir = _clean_workspace_path(body.notes_dir, "Notes directory")
    with db.session() as conn:
        db.set_notes_dir(conn, user.id, notes_dir)
    return {"ok": True, "notes_dir": notes_dir}


@app.get("/api/settings/workspace")
async def browse_workspace(user: User, path: str = Query("")) -> dict[str, Any]:
    """List directories in the agent's workspace so paths can be picked.

    This exposes no more than the account already commands: its stored token
    grants full workspace access, and its briefings may point anywhere within
    it. Picking beats typing a path and misspelling it.
    """
    try:
        safe = ark.normalize_path(path)
    except ark.ArkError as exc:
        raise HTTPException(400, str(exc)) from exc

    entries = await user.client().list_dir(safe)
    directories = sorted(
        (e for e in entries if e.is_dir and not e.name.startswith(".")),
        key=lambda e: e.name.lower(),
    )
    files = [e for e in entries if not e.is_dir and not e.name.startswith(".")]
    return {
        "path": safe,
        "parent": safe.rsplit("/", 1)[0] if "/" in safe else ("" if safe else None),
        "directories": [
            {"name": e.name, "path": ark.join(safe, e.name)} for e in directories
        ],
        # A count of what's here is usually enough to recognise a brief folder.
        "file_count": len(files),
        "pdf_count": sum(1 for e in files if e.name.lower().endswith(".pdf")),
    }


# --- briefings -------------------------------------------------------------


def _briefing_or_404(user: Principal, briefing_id: int) -> sqlite3.Row:
    with db.session() as conn:
        row = db.get_briefing(conn, user.id, briefing_id)
    if row is None:
        raise HTTPException(404, "no such briefing")
    return row


def _require_within(root: str, path: str) -> str:
    """Confine a client-supplied path to a briefing's directory.

    Ark blocks traversal out of the workspace, but not from one briefing into
    another part of it — that boundary is Vista's to enforce.
    """
    safe_root = ark.normalize_path(root)
    safe_path = ark.normalize_path(path)
    if safe_root and not (safe_path == safe_root or safe_path.startswith(safe_root + "/")):
        raise HTTPException(400, "path is outside this briefing")
    return safe_path


@app.get("/api/briefings")
def list_briefings(user: User) -> list[dict[str, Any]]:
    with db.session() as conn:
        rows = db.list_briefings(conn, user.id)
    return [{"id": r["id"], "name": r["name"], "path": r["path"]} for r in rows]


@app.post("/api/briefings", status_code=201)
def create_briefing(user: User, body: BriefingInput) -> dict[str, Any]:
    path = _clean_workspace_path(body.path, "Brief location")
    with db.session() as conn:
        briefing_id = db.add_briefing(conn, user.id, name=body.name, path=path)
    return {"id": briefing_id, "name": body.name.strip(), "path": path}


@app.put("/api/briefings/{briefing_id}")
def edit_briefing(briefing_id: int, user: User, body: BriefingInput) -> dict[str, Any]:
    _briefing_or_404(user, briefing_id)
    path = _clean_workspace_path(body.path, "Brief location")
    with db.session() as conn:
        db.update_briefing(conn, user.id, briefing_id, name=body.name, path=path)
    return {"id": briefing_id, "name": body.name.strip(), "path": path}


@app.delete("/api/briefings/{briefing_id}")
def remove_briefing(briefing_id: int, user: User) -> dict[str, Any]:
    """Remove a brief location from Vista. The files themselves are left
    alone — this unconfigures a briefing, it does not delete briefs."""
    with db.session() as conn:
        if not db.remove_briefing(conn, user.id, briefing_id):
            raise HTTPException(404, "no such briefing")
    return {"ok": True}


@app.post("/api/briefings/reorder")
def reorder_briefings(user: User, body: BriefingOrder) -> dict[str, Any]:
    with db.session() as conn:
        db.reorder_briefings(conn, user.id, body.ids)
        rows = db.list_briefings(conn, user.id)
    return {"briefings": [{"id": r["id"], "name": r["name"], "path": r["path"]} for r in rows]}


@app.get("/api/briefings/{briefing_id}/briefs")
async def list_briefs(
    briefing_id: int,
    user: User,
    sort: str = Query("date", pattern="^(date|name)$"),
    order: str = Query("desc", pattern="^(asc|desc)$"),
) -> dict[str, Any]:
    briefing = _briefing_or_404(user, briefing_id)
    found = await briefs_mod.list_briefs(user.client(), briefing["path"])
    ordered = briefs_mod.sort_briefs(found, sort, order)
    return {
        "briefing": {
            "id": briefing["id"],
            "name": briefing["name"],
            "path": briefing["path"],
        },
        "sort": sort,
        "order": order,
        "briefs": [b.to_json() for b in ordered],
    }


@app.get("/api/briefings/{briefing_id}/file")
async def get_brief_file(
    briefing_id: int,
    user: User,
    path: str = Query(..., description="workspace-relative path inside the briefing"),
    range: Annotated[str | None, Header()] = None,
) -> Response:
    """Stream a brief's bytes, preserving Range so viewers can page in."""
    briefing = _briefing_or_404(user, briefing_id)
    safe = _require_within(briefing["path"], path)

    status, headers, body = await user.client().stream_file(safe, range)
    media_type = "application/pdf" if safe.lower().endswith(".pdf") else "text/plain; charset=utf-8"
    headers.setdefault("accept-ranges", "bytes")
    headers["content-disposition"] = f'inline; filename="{safe.rsplit("/", 1)[-1]}"'
    headers["cache-control"] = "private, max-age=60"
    return StreamingResponse(body, status_code=status, headers=headers, media_type=media_type)


@app.put("/api/briefings/{briefing_id}/annotation")
async def save_annotation(
    briefing_id: int,
    user: User,
    request: Request,
    path: str = Query(..., description="workspace-relative path of the original brief PDF"),
) -> dict[str, Any]:
    """Write an Apple Markup copy of a brief back to the workspace.

    Non-destructive: the marked-up PDF is saved beside the original as
    `<name>.annotated.pdf`, so the source brief is never modified.
    """
    briefing = _briefing_or_404(user, briefing_id)
    safe = _require_within(briefing["path"], path)
    if not safe.lower().endswith(".pdf"):
        raise HTTPException(400, "annotations can only be saved for PDF briefs")

    data = await request.body()
    if not data:
        raise HTTPException(400, "empty request body")
    if not data.startswith(b"%PDF"):
        raise HTTPException(400, "body does not look like a PDF")

    target = briefs_mod.annotated_path_for(safe)
    result = await user.client().write_file(target, data)
    return {"ok": True, "path": target, "size": result.get("size", len(data))}


@app.delete("/api/briefings/{briefing_id}/annotation")
async def delete_annotation(
    briefing_id: int,
    user: User,
    path: str = Query(..., description="workspace-relative path of the brief PDF"),
) -> dict[str, Any]:
    """Discard markup and fall back to the original brief."""
    briefing = _briefing_or_404(user, briefing_id)
    safe = _require_within(briefing["path"], path)
    target = briefs_mod.annotated_path_for(safe)
    await user.client().delete(target)
    return {"ok": True, "path": target}


# --- notes -----------------------------------------------------------------


@app.get("/api/notes")
async def list_notes(
    user: User,
    sort: str = Query("date", pattern="^(date|name)$"),
    order: str = Query("desc", pattern="^(asc|desc)$"),
    preview: bool = Query(True),
) -> dict[str, Any]:
    found = await notes_mod.list_notes(user.client(), user.notes_dir, with_preview=preview)
    ordered = notes_mod.sort_notes(found, sort, order)
    return {
        "notes_dir": user.notes_dir,
        "sort": sort,
        "order": order,
        "notes": [n.to_json() for n in ordered],
    }


@app.post("/api/notes", status_code=201)
async def create_note(user: User, body: NoteCreate) -> dict[str, Any]:
    client = user.client()
    name = await notes_mod.unique_name(client, user.notes_dir, body.title)
    path = notes_mod.resolve_name(name, user.notes_dir)
    await client.write_file(path, body.content.encode("utf-8"))
    return {
        "name": name,
        "title": PurePosixPath(name).stem,
        "path": path,
        "content": body.content,
    }


@app.get("/api/notes/item")
async def read_note(user: User, name: str = Query(...)) -> dict[str, Any]:
    path = _note_path(name, user)
    raw = await user.client().read_file(path)
    return {
        "name": name,
        "title": PurePosixPath(name).stem,
        "path": path,
        "content": raw.decode("utf-8", errors="replace"),
    }


@app.put("/api/notes/item")
async def write_note(user: User, body: NoteUpdate, name: str = Query(...)) -> dict[str, Any]:
    path = _note_path(name, user)
    result = await user.client().write_file(path, body.content.encode("utf-8"))
    return {"ok": True, "name": name, "path": path, "size": result.get("size")}


@app.delete("/api/notes/item")
async def delete_note(user: User, name: str = Query(...)) -> dict[str, Any]:
    path = _note_path(name, user)
    await user.client().delete(path)
    return {"ok": True, "name": name}


@app.post("/api/notes/item/rename")
async def rename_note(user: User, body: NoteRename, name: str = Query(...)) -> dict[str, Any]:
    client = user.client()
    source = _note_path(name, user)
    new_name = await notes_mod.unique_name(client, user.notes_dir, body.title)
    dest = notes_mod.resolve_name(new_name, user.notes_dir)
    if dest == source:
        return {"ok": True, "name": name, "path": source}
    await client.rename(source, dest)
    return {"ok": True, "name": new_name, "title": PurePosixPath(new_name).stem, "path": dest}


def _note_path(name: str, user: Principal) -> str:
    try:
        return notes_mod.resolve_name(name, user.notes_dir)
    except notes_mod.NoteError as exc:
        raise HTTPException(400, str(exc)) from exc
