"""End-to-end API tests: a real HTTP client against the Vista app, backed by
a real Ark server."""

from __future__ import annotations

import asyncio
import uuid

import pytest
from fastapi.testclient import TestClient

from vista import ark, db, security
from vista.app import app
from vista.ark import ArkClient

from conftest import ARK_AGENT, ARK_TOKEN, ARK_URL, requires_ark

pytestmark = requires_ark

PASSWORD = "correct-horse-battery-staple"


@pytest.fixture
def account():
    """A provisioned user with a briefing and notes dir of their own."""
    root = f"vista-api-tests/{uuid.uuid4().hex[:12]}"
    email = f"{uuid.uuid4().hex[:8]}@example.com"
    client = ArkClient(ARK_URL, ARK_TOKEN, ARK_AGENT)

    async def seed() -> None:
        await client.write_file(f"{root}/briefs/AI_Policy_Brief-2026-06-15.pdf", b"%PDF-1.4 newer")
        await client.write_file(f"{root}/briefs/AI_Policy_Brief-2026-06-15.md", b"# source")
        await client.write_file(f"{root}/briefs/AI_Policy_Brief-2026-06-01.pdf", b"%PDF-1.4 older")
        await client.write_file(f"{root}/private/secret.pdf", b"%PDF-1.4 not a brief")

    asyncio.run(seed())

    db.init()
    with db.session() as conn:
        user_id = db.create_user(
            conn, email=email, password_hash=security.hash_password(PASSWORD)
        )
        db.set_ark_connection(
            conn,
            user_id,
            base_url=ARK_URL,
            token_enc=security.encrypt_secret(ARK_TOKEN),
            agent=ARK_AGENT,
            notes_dir=f"{root}/notes",
        )
        briefing_id = db.add_briefing(
            conn, user_id, name="Policy Briefs", path=f"{root}/briefs"
        )

    yield {"email": email, "briefing_id": briefing_id, "root": root}

    async def cleanup() -> None:
        try:
            await client.delete(root)
        except ark.ArkError:
            pass

    asyncio.run(cleanup())
    with db.session() as conn:
        db.delete_user(conn, user_id)


@pytest.fixture
def api(account):
    """An authenticated client, plus the account it belongs to."""
    with TestClient(app) as client:
        resp = client.post(
            "/api/auth/login", json={"email": account["email"], "password": PASSWORD}
        )
        assert resp.status_code == 200, resp.text
        client.headers["Authorization"] = f"Bearer {resp.json()['token']}"
        yield client, account


# --- auth ------------------------------------------------------------------


def test_login_rejects_a_bad_password(account) -> None:
    with TestClient(app) as client:
        resp = client.post(
            "/api/auth/login", json={"email": account["email"], "password": "wrong"}
        )
    assert resp.status_code == 401


def test_login_rejects_an_unknown_account() -> None:
    with TestClient(app) as client:
        resp = client.post(
            "/api/auth/login", json={"email": "nobody@example.com", "password": "x"}
        )
    assert resp.status_code == 401


def test_endpoints_require_authentication() -> None:
    with TestClient(app) as client:
        assert client.get("/api/notes").status_code == 401
        assert client.get("/api/briefings").status_code == 401


def test_me_reports_the_configured_briefings(api) -> None:
    client, account = api
    body = client.get("/api/me").json()
    assert body["configured"] is True
    assert [b["name"] for b in body["briefings"]] == ["Policy Briefs"]


def test_ark_status_confirms_the_connection(api) -> None:
    client, _ = api
    body = client.get("/api/ark/status").json()
    assert body["connected"] is True
    assert body["agent"] == ARK_AGENT


# --- briefs ----------------------------------------------------------------


def test_briefs_list_collapses_variants_and_sorts_by_date(api) -> None:
    client, account = api
    body = client.get(f"/api/briefings/{account['briefing_id']}/briefs").json()

    titles = [b["title"] for b in body["briefs"]]
    dates = [b["date"][:10] for b in body["briefs"]]
    assert titles == ["AI Policy Brief", "AI Policy Brief"]
    assert dates == ["2026-06-15", "2026-06-01"], "newest first by default"
    assert body["briefs"][0]["date_source"] == "filename"
    assert body["briefs"][0]["annotated"] is False


def test_briefs_can_be_sorted_by_name_and_reversed(api) -> None:
    client, account = api
    base = f"/api/briefings/{account['briefing_id']}/briefs"

    ascending = client.get(base, params={"sort": "date", "order": "asc"}).json()
    assert [b["date"][:10] for b in ascending["briefs"]] == ["2026-06-01", "2026-06-15"]

    by_name = client.get(base, params={"sort": "name"}).json()
    assert len(by_name["briefs"]) == 2
    assert by_name["sort"] == "name"


def test_brief_file_streams_with_range_support(api) -> None:
    client, account = api
    listing = client.get(f"/api/briefings/{account['briefing_id']}/briefs").json()
    path = listing["briefs"][0]["pdf_path"]

    full = client.get(f"/api/briefings/{account['briefing_id']}/file", params={"path": path})
    assert full.status_code == 200
    assert full.content == b"%PDF-1.4 newer"
    assert full.headers["content-type"].startswith("application/pdf")

    partial = client.get(
        f"/api/briefings/{account['briefing_id']}/file",
        params={"path": path},
        headers={"Range": "bytes=0-3"},
    )
    assert partial.status_code == 206, "PDF viewers need partial content"
    assert partial.content == b"%PDF"


def test_brief_file_refuses_paths_outside_the_briefing(api) -> None:
    """A briefing is a boundary — Ark alone would happily serve the whole
    workspace."""
    client, account = api
    escape = f"{account['root']}/private/secret.pdf"

    resp = client.get(
        f"/api/briefings/{account['briefing_id']}/file", params={"path": escape}
    )
    assert resp.status_code == 400
    assert b"not a brief" not in resp.content


def test_brief_file_refuses_traversal(api) -> None:
    client, account = api
    resp = client.get(
        f"/api/briefings/{account['briefing_id']}/file",
        params={"path": "../../../etc/passwd"},
    )
    assert resp.status_code == 400


def test_briefing_of_another_user_is_not_reachable(api) -> None:
    client, _ = api
    assert client.get("/api/briefings/999999/briefs").status_code == 404


# --- annotations -----------------------------------------------------------


def test_saving_markup_writes_a_sidecar_and_preserves_the_original(api) -> None:
    client, account = api
    briefing_id = account["briefing_id"]
    listing = client.get(f"/api/briefings/{briefing_id}/briefs").json()
    original_path = listing["briefs"][0]["pdf_path"]

    saved = client.put(
        f"/api/briefings/{briefing_id}/annotation",
        params={"path": original_path},
        content=b"%PDF-1.4 marked up by apple markup",
    )
    assert saved.status_code == 200, saved.text
    assert saved.json()["path"].endswith(".annotated.pdf")

    # The original brief is byte-for-byte untouched.
    original = client.get(
        f"/api/briefings/{briefing_id}/file", params={"path": original_path}
    )
    assert original.content == b"%PDF-1.4 newer"

    # The brief now reports markup, and reading it defaults to the marked-up copy.
    relisted = client.get(f"/api/briefings/{briefing_id}/briefs").json()
    brief = next(b for b in relisted["briefs"] if b["pdf_path"] == original_path)
    assert brief["annotated"] is True
    assert brief["primary_path"] == brief["annotated_path"]
    assert len(relisted["briefs"]) == 2, "markup must not become its own brief"

    marked = client.get(
        f"/api/briefings/{briefing_id}/file", params={"path": brief["annotated_path"]}
    )
    assert marked.content == b"%PDF-1.4 marked up by apple markup"

    # Discarding markup falls back to the original.
    dropped = client.delete(
        f"/api/briefings/{briefing_id}/annotation", params={"path": original_path}
    )
    assert dropped.status_code == 200
    after = client.get(f"/api/briefings/{briefing_id}/briefs").json()
    assert all(b["annotated"] is False for b in after["briefs"])


def test_annotation_rejects_non_pdf_bodies(api) -> None:
    client, account = api
    listing = client.get(f"/api/briefings/{account['briefing_id']}/briefs").json()
    path = listing["briefs"][0]["pdf_path"]

    resp = client.put(
        f"/api/briefings/{account['briefing_id']}/annotation",
        params={"path": path},
        content=b"this is not a pdf",
    )
    assert resp.status_code == 400


def test_annotation_refuses_paths_outside_the_briefing(api) -> None:
    client, account = api
    resp = client.put(
        f"/api/briefings/{account['briefing_id']}/annotation",
        params={"path": f"{account['root']}/private/secret.pdf"},
        content=b"%PDF-1.4 evil",
    )
    assert resp.status_code == 400


# --- notes -----------------------------------------------------------------


def test_note_lifecycle(api) -> None:
    client, _ = api

    created = client.post(
        "/api/notes", json={"title": "Standup", "content": "# Standup\n\n- one\n"}
    )
    assert created.status_code == 201, created.text
    name = created.json()["name"]
    assert name == "Standup.md"

    listed = client.get("/api/notes").json()["notes"]
    assert [n["name"] for n in listed] == ["Standup.md"]
    assert listed[0]["preview"] == "one", "the title heading is not repeated in its own preview"

    read = client.get("/api/notes/item", params={"name": name}).json()
    assert read["content"] == "# Standup\n\n- one\n"

    updated = client.put(
        "/api/notes/item", params={"name": name}, json={"content": "# Standup\n\nedited\n"}
    )
    assert updated.status_code == 200
    assert client.get("/api/notes/item", params={"name": name}).json()["content"] == (
        "# Standup\n\nedited\n"
    )

    renamed = client.post(
        "/api/notes/item/rename", params={"name": name}, json={"title": "Standup Notes"}
    )
    assert renamed.status_code == 200
    assert renamed.json()["name"] == "Standup Notes.md"
    assert client.get("/api/notes/item", params={"name": name}).status_code == 404

    deleted = client.delete("/api/notes/item", params={"name": "Standup Notes.md"})
    assert deleted.status_code == 200
    assert client.get("/api/notes").json()["notes"] == []


def test_creating_two_notes_with_one_title_does_not_clobber(api) -> None:
    client, _ = api
    first = client.post("/api/notes", json={"title": "Meeting", "content": "first"})
    second = client.post("/api/notes", json={"title": "Meeting", "content": "second"})

    assert first.json()["name"] == "Meeting.md"
    assert second.json()["name"] == "Meeting-2.md"
    assert client.get("/api/notes/item", params={"name": "Meeting.md"}).json()["content"] == "first"


def test_untitled_note_still_gets_a_name(api) -> None:
    client, _ = api
    created = client.post("/api/notes", json={"title": "", "content": "captured thought"})
    assert created.status_code == 201
    assert created.json()["name"].endswith(".md")


def test_note_names_cannot_escape_the_notes_directory(api) -> None:
    client, _ = api
    for bad in ["../../etc/passwd", "sub/dir.md", ".."]:
        assert client.get("/api/notes/item", params={"name": bad}).status_code == 400
        assert client.delete("/api/notes/item", params={"name": bad}).status_code == 400


def test_missing_note_returns_404(api) -> None:
    client, _ = api
    assert client.get("/api/notes/item", params={"name": "nope.md"}).status_code == 404


# --- settings --------------------------------------------------------------


def test_settings_never_returns_the_ark_token(api) -> None:
    """The token is write-only. A leak here would hand a client full
    read/write access to every workspace on the Ark server."""
    client, _ = api
    body = client.get("/api/settings").json()

    assert body["ark"]["token_set"] is True
    assert "token" not in body["ark"]
    assert ARK_TOKEN not in client.get("/api/settings").text
    assert ARK_TOKEN not in client.get("/api/me").text


def test_settings_reports_current_configuration(api) -> None:
    client, account = api
    body = client.get("/api/settings").json()

    assert body["ark"]["agent"] == ARK_AGENT
    assert body["ark"]["base_url"] == ARK_URL
    assert body["notes_dir"] == f"{account['root']}/notes"
    assert [b["name"] for b in body["briefings"]] == ["Policy Briefs"]


def test_updating_the_endpoint_keeps_the_stored_token(api) -> None:
    """Editing the URL or agent in a form that cannot show the token must not
    wipe it."""
    client, _ = api
    resp = client.put(
        "/api/settings/ark", json={"base_url": ARK_URL, "agent": ARK_AGENT}
    )
    assert resp.status_code == 200
    assert resp.json()["connected"] is True
    assert client.get("/api/settings").json()["ark"]["token_set"] is True
    # And the connection still works for real requests.
    assert client.get("/api/notes").status_code == 200


def test_updating_the_token_takes_effect(api) -> None:
    client, _ = api
    saved = client.put(
        "/api/settings/ark",
        json={"base_url": ARK_URL, "agent": ARK_AGENT, "token": "wrong-token"},
    )
    assert saved.status_code == 200
    assert saved.json()["connected"] is False

    # A bad token is a server-side misconfiguration, not an expired session:
    # it must not read as 401 and bounce the user to a login screen.
    assert client.get("/api/notes").status_code == 502

    restored = client.put(
        "/api/settings/ark",
        json={"base_url": ARK_URL, "agent": ARK_AGENT, "token": ARK_TOKEN},
    )
    assert restored.json()["connected"] is True
    assert client.get("/api/notes").status_code == 200


def test_ark_url_must_be_http(api) -> None:
    client, _ = api
    resp = client.put("/api/settings/ark", json={"base_url": "ark:7777", "agent": "scribe"})
    assert resp.status_code == 400


def test_test_connection_does_not_save(api) -> None:
    client, _ = api
    probe = client.post(
        "/api/settings/ark/test",
        json={"base_url": ARK_URL, "agent": "no-such-agent", "token": ARK_TOKEN},
    )
    assert probe.status_code == 200
    assert probe.json()["connected"] is False
    # The saved configuration is untouched by a failed probe.
    assert client.get("/api/settings").json()["ark"]["agent"] == ARK_AGENT


def test_notes_directory_can_be_changed(api) -> None:
    client, account = api
    moved = f"{account['root']}/other-notes"

    client.post("/api/notes", json={"title": "In the old place", "content": "x"})
    assert client.put("/api/settings/notes", json={"notes_dir": moved}).status_code == 200

    assert client.get("/api/settings").json()["notes_dir"] == moved
    # A different directory means a different (here, empty) set of notes.
    assert client.get("/api/notes").json()["notes"] == []


@pytest.mark.parametrize("bad", ["../escape", "/absolute", "", "   "])
def test_notes_directory_rejects_bad_paths(api, bad: str) -> None:
    client, _ = api
    assert client.put("/api/settings/notes", json={"notes_dir": bad}).status_code in (400, 422)


def test_briefing_can_be_added_edited_and_removed(api) -> None:
    client, account = api
    root = account["root"]

    created = client.post(
        "/api/briefings", json={"name": "Second", "path": f"{root}/briefs"}
    )
    assert created.status_code == 201
    new_id = created.json()["id"]
    assert len(client.get("/api/briefings").json()) == 2
    # A newly configured briefing immediately serves its briefs.
    assert len(client.get(f"/api/briefings/{new_id}/briefs").json()["briefs"]) == 2

    edited = client.put(
        f"/api/briefings/{new_id}", json={"name": "Renamed", "path": f"{root}/briefs"}
    )
    assert edited.status_code == 200
    assert edited.json()["name"] == "Renamed"

    assert client.delete(f"/api/briefings/{new_id}").status_code == 200
    assert len(client.get("/api/briefings").json()) == 1
    assert client.get(f"/api/briefings/{new_id}/briefs").status_code == 404


def test_removing_a_briefing_leaves_the_files_alone(api) -> None:
    """Unconfiguring a brief location must not delete anyone's briefs."""
    client, account = api
    briefing_id = account["briefing_id"]
    listing = client.get(f"/api/briefings/{briefing_id}/briefs").json()
    path = listing["briefs"][0]["pdf_path"]

    assert client.delete(f"/api/briefings/{briefing_id}").status_code == 200

    # Re-add the same location; the briefs are all still there.
    again = client.post("/api/briefings", json={"name": "Policy", "path": f"{account['root']}/briefs"})
    restored = client.get(f"/api/briefings/{again.json()['id']}/briefs").json()
    assert [b["pdf_path"] for b in restored["briefs"]].count(path) == 1


def test_briefing_paths_are_validated(api) -> None:
    client, _ = api
    for bad in ["../../etc", "/etc/passwd"]:
        assert client.post("/api/briefings", json={"name": "x", "path": bad}).status_code == 400


def test_briefings_can_be_reordered(api) -> None:
    client, account = api
    second = client.post(
        "/api/briefings", json={"name": "Second", "path": f"{account['root']}/briefs"}
    ).json()["id"]
    first = account["briefing_id"]

    reordered = client.post("/api/briefings/reorder", json={"ids": [second, first]})
    assert [b["id"] for b in reordered.json()["briefings"]] == [second, first]
    assert [b["id"] for b in client.get("/api/briefings").json()] == [second, first]


def test_another_users_briefing_cannot_be_edited_or_removed(api) -> None:
    client, _ = api
    assert client.put("/api/briefings/999999", json={"name": "x", "path": "y"}).status_code == 404
    assert client.delete("/api/briefings/999999").status_code == 404


def test_workspace_browser_lists_directories(api) -> None:
    client, account = api
    body = client.get("/api/settings/workspace", params={"path": account["root"]}).json()

    names = [d["name"] for d in body["directories"]]
    assert "briefs" in names and "private" in names
    assert body["parent"] == account["root"].rsplit("/", 1)[0]

    briefs = client.get(
        "/api/settings/workspace", params={"path": f"{account['root']}/briefs"}
    ).json()
    assert briefs["pdf_count"] == 2, "a pdf count helps identify a brief folder"


def test_workspace_browser_refuses_traversal(api) -> None:
    client, _ = api
    assert client.get("/api/settings/workspace", params={"path": "../.."}).status_code == 400
