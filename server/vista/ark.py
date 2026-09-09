"""Client for an Ark server's agent-workspace filesystem API.

Ark exposes an agent's workspace over REST (see ark/docs/files.md):

    GET    /agents/{name}/files/{path}          # dir -> JSON listing, file -> bytes
    PUT    /agents/{name}/files/{path}          # write file (raw body)
    DELETE /agents/{name}/files/{path}
    POST   /agents/{name}/files/{path}?op=mkdir
    POST   /agents/{name}/files/{path}?op=rename&dest=...

Auth is a single bearer token that grants full access to every workspace on
the server, so the token stays here and never reaches a Vista client.
"""

from __future__ import annotations

import posixpath
import re
from dataclasses import dataclass
from typing import Any, AsyncIterator
from urllib.parse import quote

import httpx

from . import config

_DRIVE_LETTER = re.compile(r"^[A-Za-z]:")


class ArkError(RuntimeError):
    """An Ark request failed. `status` is the upstream HTTP status, if any."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class NotFound(ArkError):
    pass


@dataclass(frozen=True)
class Entry:
    name: str
    is_dir: bool
    size: int
    mtime_ms: int

    @property
    def mtime(self) -> float:
        """Ark reports directory-listing mtimes in milliseconds."""
        return self.mtime_ms / 1000.0


def normalize_path(path: str) -> str:
    """Normalize a workspace-relative path, rejecting anything that escapes.

    Ark enforces this server-side too, but catching it here gives a clearer
    error and avoids sending obviously bad paths over the wire.
    """
    if path is None:
        raise ArkError("path is required", 400)
    raw = path.strip()
    if not raw:
        return ""
    # Test for absoluteness *before* stripping separators, or the check can
    # never fire. Ark refuses absolute paths too; matching it keeps the
    # failure mode identical wherever the check happens to run.
    if raw[0] in "/\\" or _DRIVE_LETTER.match(raw):
        raise ArkError(f"path must be workspace-relative: {path!r}", 400)
    normalized = posixpath.normpath(raw.strip("/"))
    if normalized == "." :
        return ""
    parts = normalized.split("/")
    if any(p == ".." for p in parts):
        raise ArkError(f"path escapes the workspace: {path!r}", 400)
    return "/".join(p for p in parts if p and p != ".")


def join(*parts: str) -> str:
    """Join workspace-relative path segments, dropping empties."""
    return "/".join(p.strip("/") for p in parts if p and p.strip("/"))


def _encode(path: str) -> str:
    # Encode each segment but keep the separators — the route is {path:path}.
    return "/".join(quote(seg, safe="") for seg in path.split("/") if seg)


class ArkClient:
    """Talks to one agent's workspace on one Ark server."""

    def __init__(self, base_url: str, token: str, agent: str):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.agent = agent

    # -- plumbing ----------------------------------------------------------

    def _url(self, path: str) -> str:
        encoded = _encode(path)
        root = f"{self.base_url}/agents/{quote(self.agent, safe='')}/files"
        return f"{root}/{encoded}" if encoded else root

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=config.HTTP_TIMEOUT, follow_redirects=False)

    @staticmethod
    def _raise_for(resp: httpx.Response, path: str) -> None:
        if resp.status_code < 400:
            return
        detail = ""
        try:
            body = resp.json()
            detail = body.get("detail") or body.get("error") or ""
        except Exception:
            detail = (resp.text or "")[:200]
        if resp.status_code == 404:
            raise NotFound(f"not found in workspace: {path!r}", 404)
        if resp.status_code == 401:
            raise ArkError(
                "Ark rejected the stored credentials (401) — check the token", 401
            )
        raise ArkError(
            f"Ark returned {resp.status_code} for {path!r}"
            + (f": {detail}" if detail else ""),
            resp.status_code,
        )

    async def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        safe = normalize_path(path)
        # Merge rather than overwrite: callers pass their own headers too
        # (Content-Type on writes), and the auth header must survive.
        headers = {**self._headers(), **(kwargs.pop("headers", None) or {})}
        async with self._client() as client:
            try:
                resp = await client.request(
                    method, self._url(safe), headers=headers, **kwargs
                )
            except httpx.RequestError as exc:
                raise ArkError(f"could not reach Ark at {self.base_url}: {exc}") from exc
        self._raise_for(resp, safe)
        return resp

    # -- operations --------------------------------------------------------

    async def list_dir(self, path: str = "") -> list[Entry]:
        resp = await self._request("GET", path)
        ctype = resp.headers.get("content-type", "")
        if "application/json" not in ctype:
            raise ArkError(f"not a directory: {path!r}", 400)
        payload = resp.json()
        return [
            Entry(
                name=e["name"],
                is_dir=bool(e["is_dir"]),
                size=int(e.get("size") or 0),
                mtime_ms=int(e.get("mtime") or 0),
            )
            for e in payload.get("entries", [])
        ]

    async def read_file(self, path: str) -> bytes:
        resp = await self._request("GET", path)
        if "application/json" in resp.headers.get("content-type", ""):
            raise ArkError(f"is a directory, not a file: {path!r}", 400)
        return resp.content

    async def write_file(self, path: str, data: bytes) -> dict[str, Any]:
        resp = await self._request(
            "PUT", path, content=data, headers={"Content-Type": "application/octet-stream"}
        )
        return resp.json()

    async def delete(self, path: str) -> None:
        await self._request("DELETE", path)

    async def mkdir(self, path: str) -> None:
        await self._request("POST", path, params={"op": "mkdir"})

    async def rename(self, path: str, dest: str) -> None:
        await self._request(
            "POST", path, params={"op": "rename", "dest": normalize_path(dest)}
        )

    async def exists(self, path: str) -> bool:
        try:
            await self._request("GET", path)
            return True
        except NotFound:
            return False

    async def stream_file(
        self, path: str, range_header: str | None = None
    ) -> tuple[int, dict[str, str], AsyncIterator[bytes]]:
        """Stream a file through, preserving Range semantics.

        Ark serves files with Starlette's FileResponse, which honors Range and
        replies 206 — so a PDF viewer can page into a large brief instead of
        pulling the whole file. The response body is consumed lazily; the
        caller must exhaust the iterator to release the connection.
        """
        safe = normalize_path(path)
        headers = self._headers()
        if range_header:
            headers["Range"] = range_header

        client = self._client()
        try:
            req = client.build_request("GET", self._url(safe), headers=headers)
            resp = await client.send(req, stream=True)
        except httpx.RequestError as exc:
            await client.aclose()
            raise ArkError(f"could not reach Ark at {self.base_url}: {exc}") from exc

        if resp.status_code >= 400:
            try:
                await resp.aread()
                self._raise_for(resp, safe)
            finally:
                await resp.aclose()
                await client.aclose()

        passthrough = {}
        for header in ("content-length", "content-range", "accept-ranges", "etag", "last-modified"):
            if header in resp.headers:
                passthrough[header] = resp.headers[header]

        async def body() -> AsyncIterator[bytes]:
            try:
                async for chunk in resp.aiter_bytes():
                    yield chunk
            finally:
                await resp.aclose()
                await client.aclose()

        return resp.status_code, passthrough, body()
