"""
Integration tests for brain API endpoints.

These tests run against an ephemeral Kuzu graph — no live DB needed.
"""

import pytest


# ── Schema ───────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_schema_returns_tables(brain_client):
    resp = await brain_client.get("/api/brain/schema")
    assert resp.status_code == 200
    data = resp.json()
    assert "node_tables" in data
    table_names = [t["name"] for t in data["node_tables"]]
    assert "Note" in table_names
    assert "Chat" in table_names


# ── Write + read notes ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_write_context_note(brain_client):
    resp = await brain_client.post("/api/brain/notes", json={
        "note_type": "context",
        "title": "Profile",
        "content": "Name: Test User",
    })
    assert resp.status_code == 200
    data = resp.json()
    assert data["entry_id"] == "context:profile"
    assert data["status"] == "updated"


@pytest.mark.asyncio
async def test_write_context_note_upsert(brain_client):
    """Writing the same context note twice updates it, doesn't duplicate."""
    await brain_client.post("/api/brain/notes", json={
        "note_type": "context",
        "title": "Now",
        "content": "Version 1",
    })
    resp = await brain_client.post("/api/brain/notes", json={
        "note_type": "context",
        "title": "Now",
        "content": "Version 2",
    })
    assert resp.status_code == 200

    # Should be exactly one note with this entry_id
    query_resp = await brain_client.post("/api/brain/query", json={
        "query": 'MATCH (n:Note {entry_id: "context:now"}) RETURN n.content',
    })
    rows = query_resp.json()["rows"]
    assert len(rows) == 1
    assert rows[0]["n.content"] == "Version 2"


@pytest.mark.asyncio
async def test_write_context_note_sets_updated_at(brain_client):
    resp = await brain_client.post("/api/brain/notes", json={
        "note_type": "context",
        "title": "TestUpdated",
        "content": "Check timestamps",
    })
    assert resp.status_code == 200

    query_resp = await brain_client.post("/api/brain/query", json={
        "query": 'MATCH (n:Note {entry_id: "context:testupdated"}) RETURN n.updated_at, n.created_at',
    })
    row = query_resp.json()["rows"][0]
    assert row["n.updated_at"] != ""
    assert row["n.created_at"] != ""


@pytest.mark.asyncio
async def test_write_journal_note(brain_client):
    resp = await brain_client.post("/api/brain/notes", json={
        "note_type": "journal",
        "title": "Morning thoughts",
        "content": "Feeling good today",
        "date": "2026-03-22",
    })
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "created"
    assert data["note_type"] == "journal"
    assert not data["entry_id"].startswith("context:")


@pytest.mark.asyncio
async def test_write_note_validation(brain_client):
    # Empty content
    resp = await brain_client.post("/api/brain/notes", json={
        "note_type": "context",
        "title": "Bad",
        "content": "",
    })
    assert resp.status_code == 400


# ── List notes ───────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_list_notes_empty(brain_client):
    resp = await brain_client.get("/api/brain/daily/entries")
    assert resp.status_code == 200
    data = resp.json()
    assert data["entries"] == []


@pytest.mark.asyncio
async def test_list_notes_after_write(brain_client):
    await brain_client.post("/api/brain/notes", json={
        "note_type": "context",
        "title": "Profile",
        "content": "Test user profile",
    })
    resp = await brain_client.get("/api/brain/daily/entries", params={
        "note_type": "context",
    })
    assert resp.status_code == 200
    entries = resp.json()["entries"]
    assert len(entries) >= 1
    assert any(e["title"] == "Profile" for e in entries)


# ── Cypher passthrough ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_query_read_only(brain_client):
    resp = await brain_client.post("/api/brain/query", json={
        "query": "MATCH (n:Note) RETURN n.entry_id LIMIT 5",
    })
    assert resp.status_code == 200
    data = resp.json()
    assert "rows" in data
    assert "count" in data


@pytest.mark.asyncio
async def test_execute_write(brain_client):
    resp = await brain_client.post("/api/brain/execute", json={
        "query": 'MERGE (n:Note {entry_id: "test:execute"}) SET n.content = "written via execute"',
    })
    assert resp.status_code == 200
    assert resp.json()["ok"] is True

    # Verify it was written
    query_resp = await brain_client.post("/api/brain/query", json={
        "query": 'MATCH (n:Note {entry_id: "test:execute"}) RETURN n.content',
    })
    assert query_resp.json()["rows"][0]["n.content"] == "written via execute"


# ── Memory search ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_memory_search_empty(brain_client):
    resp = await brain_client.get("/api/brain/memory", params={"query": "nonexistent"})
    assert resp.status_code == 200
    assert resp.json()["items"] == []


@pytest.mark.asyncio
async def test_memory_search_finds_note(brain_client):
    await brain_client.post("/api/brain/notes", json={
        "note_type": "journal",
        "title": "Taiji practice",
        "content": "Morning taiji by the creek, felt grounded",
        "date": "2026-03-22",
    })
    resp = await brain_client.get("/api/brain/memory", params={"query": "taiji"})
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert len(items) >= 1


# ── Chats ────────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_list_chats_empty(brain_client):
    resp = await brain_client.get("/api/brain/chats")
    assert resp.status_code == 200
    data = resp.json()
    assert data["chats"] == []


@pytest.mark.asyncio
async def test_search_chats_empty(brain_client):
    resp = await brain_client.get("/api/brain/chats/search", params={"query": "test"})
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_get_chat_not_found(brain_client):
    resp = await brain_client.get("/api/brain/chats/nonexistent-id")
    # May return 404 or 200 with error — either is acceptable
    assert resp.status_code in (200, 404)


# ── Exchanges ────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_exchange_not_found(brain_client):
    resp = await brain_client.get("/api/brain/exchanges", params={"id": "nonexistent"})
    assert resp.status_code in (200, 404)


# ── Containers ───────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_list_containers_empty(brain_client):
    resp = await brain_client.get("/api/brain/containers")
    assert resp.status_code == 200
    data = resp.json()
    assert data["containers"] == []
