"""
Unit tests for DailyModule with Kuzu graph as primary storage.

Tests the full CRUD cycle: create, list, get, update, delete, search.
Uses a real temporary Kuzu database (no mocks for graph operations) to
verify that Cypher queries, schema migrations, and result shapes are correct.
"""

import asyncio
import tempfile
from pathlib import Path

import pytest
import pytest_asyncio

from modules.daily.module import DailyModule
from parachute.db.brain import BrainService
from parachute.db.brain_chat_store import BrainChatStore

# Skip entire module if LadybugDB native layer is broken on this platform
from tests.conftest import LADYBUGDB_WORKS
pytestmark = pytest.mark.skipif(
    not LADYBUGDB_WORKS,
    reason="LadybugDB native layer has ANY type bug on this platform",
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture
async def tmp_vault(tmp_path):
    """Temporary vault directory with Daily/entries/ subdirectory."""
    vault = tmp_path / "vault"
    vault.mkdir()
    return vault


@pytest_asyncio.fixture
async def graph(tmp_path):
    """Live temporary Kuzu database for testing.

    Runs BrainChatStore.ensure_schema() to register all core tables
    (Note, Card, Agent, etc.) before modules load — same as server startup.
    Probes with a real MERGE to detect LadybugDB's "ANY type" bug early.
    """
    db_path = tmp_path / "graph.db"
    svc = BrainService(db_path)
    await svc.connect()
    store = BrainChatStore(svc)
    await store.ensure_schema()

    # Probe: test a multi-param MERGE matching what daily module actually does.
    # On Linux, LadybugDB's native layer fails with "ANY type" on complex
    # parameterized queries AFTER typed columns are added by ensure_schema().
    try:
        await svc.execute_cypher(
            "MERGE (e:Note {entry_id: $entry_id}) "
            "ON CREATE SET e.created_at = $created_at, "
            "    e.note_type = $note_type, e.aliases = $aliases, "
            "    e.status = $status, e.created_by = $created_by "
            "SET e.date = $date, e.content = $content, e.snippet = $snippet, "
            "    e.title = $title, e.entry_type = $entry_type, "
            "    e.audio_path = $audio_path, "
            "    e.metadata_json = $metadata_json, "
            "    e.brain_links_json = $brain_links_json",
            {
                "entry_id": "__probe__",
                "date": "2000-01-01",
                "content": "probe",
                "snippet": "probe",
                "created_at": "2000-01-01T00:00:00",
                "title": "",
                "entry_type": "text",
                "audio_path": "",
                "note_type": "journal",
                "aliases": "[]",
                "status": "active",
                "created_by": "user",
                "metadata_json": "{}",
                "brain_links_json": "[]",
            },
        )
        # Clean up probe node
        await svc.execute_cypher(
            "MATCH (e:Note {entry_id: '__probe__'}) DELETE e"
        )
    except RuntimeError as e:
        if "ANY type" in str(e):
            pytest.skip(f"LadybugDB parameterized MERGE broken: {e}")
        raise

    yield svc
    # Clean up connection state. The __del__ deadlock/segfault is handled
    # globally in conftest.py (neutralized process-wide for all tests).
    if svc._conn:
        conn = svc._conn
        if hasattr(conn, "executor") and conn.executor:
            conn.executor.shutdown(wait=False, cancel_futures=True)
    svc._connected = False
    svc._conn = None
    svc._db = None


@pytest_asyncio.fixture
async def module(tmp_vault, graph, monkeypatch):
    """DailyModule wired to the temporary graph.

    Monkeypatches _get_graph directly on the instance so the module
    never touches the global InterfaceRegistry (and therefore never
    writes to the production BrainDB).
    """
    mod = DailyModule(home_path=tmp_vault)
    monkeypatch.setattr(mod, "_get_graph", lambda: graph)
    await mod.on_load()
    return mod


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

class TestSchema:
    async def test_journal_entry_table_created(self, module, graph):
        cols = await graph.get_table_columns("Note")
        assert "entry_id" in cols
        assert "content" in cols
        assert "title" in cols
        assert "entry_type" in cols
        assert "audio_path" in cols
        assert "metadata_json" in cols
        assert "brain_links_json" in cols


    async def test_on_load_idempotent(self, module):
        """Calling on_load() a second time should not error."""
        await module.on_load()


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

class TestCreateEntry:
    async def test_create_returns_id_and_timestamp(self, module):
        result = await module.create_entry("Hello world")
        assert "id" in result
        assert "created_at" in result
        assert result["id"].startswith("20")  # "YYYY-MM-DD-..."

    async def test_created_entry_appears_in_list(self, module):
        await module.create_entry("First entry")
        entries = await module.list_entries()
        assert len(entries) == 1
        assert entries[0]["content"] == "First entry"

    async def test_create_with_metadata(self, module):
        await module.create_entry(
            "Voice note",
            metadata={"type": "voice", "title": "Morning note", "audio_path": "Daily/assets/test.wav"},
        )
        entries = await module.list_entries()
        entry = entries[0]
        assert entry["metadata"]["type"] == "voice"
        assert entry["metadata"]["title"] == "Morning note"
        assert entry["metadata"]["audio_path"] == "Daily/assets/test.wav"

    async def test_create_multiple_entries(self, module):
        await module.create_entry("Entry one")
        await asyncio.sleep(0.01)  # ensure distinct timestamps
        await module.create_entry("Entry two")
        entries = await module.list_entries()
        assert len(entries) == 2
        # Newest first
        assert entries[0]["content"] == "Entry two"
        assert entries[1]["content"] == "Entry one"


# ---------------------------------------------------------------------------
# Get
# ---------------------------------------------------------------------------

class TestGetEntry:
    async def test_get_existing_entry(self, module):
        result = await module.create_entry("Test content")
        entry = await module.get_entry(result["id"])
        assert entry is not None
        assert entry["content"] == "Test content"
        assert entry["id"] == result["id"]

    async def test_get_nonexistent_returns_none(self, module):
        entry = await module.get_entry("2000-01-01-00-00-00")
        assert entry is None


# ---------------------------------------------------------------------------
# List with date filter
# ---------------------------------------------------------------------------

class TestListEntries:
    async def test_date_filter_returns_matching_entries(self, module):
        result = await module.create_entry("Today's entry")
        entry_id = result["id"]
        date = entry_id[:10]  # YYYY-MM-DD

        entries = await module.list_entries(date=date)
        assert len(entries) == 1
        assert entries[0]["content"] == "Today's entry"

    async def test_date_filter_excludes_other_dates(self, module):
        await module.create_entry("Entry")
        entries = await module.list_entries(date="1999-01-01")
        assert len(entries) == 0

    async def test_pagination(self, module):
        for i in range(5):
            await module.create_entry(f"Entry {i}")
            await asyncio.sleep(0.01)
        page1 = await module.list_entries(limit=3, offset=0)
        page2 = await module.list_entries(limit=3, offset=3)
        assert len(page1) == 3
        assert len(page2) == 2
        # No overlap
        ids1 = {e["id"] for e in page1}
        ids2 = {e["id"] for e in page2}
        assert not ids1 & ids2


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

class TestUpdateEntry:
    async def test_update_content(self, module):
        result = await module.create_entry("Original content")
        updated = await module.update_entry(result["id"], content="Updated content")
        assert updated is not None
        assert updated["content"] == "Updated content"
        assert updated["snippet"] == "Updated content"

    async def test_update_persisted(self, module):
        result = await module.create_entry("Original")
        await module.update_entry(result["id"], content="Persisted update")
        fetched = await module.get_entry(result["id"])
        assert fetched["content"] == "Persisted update"

    async def test_update_metadata(self, module):
        result = await module.create_entry("Content", metadata={"type": "text"})
        updated = await module.update_entry(result["id"], metadata={"title": "New title"})
        assert updated["metadata"]["title"] == "New title"
        # Original type preserved
        assert updated["metadata"]["type"] == "text"

    async def test_update_nonexistent_returns_none(self, module):
        result = await module.update_entry("2000-01-01-00-00-00", content="x")
        assert result is None


# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------

class TestDeleteEntry:
    async def test_delete_removes_entry(self, module):
        result = await module.create_entry("To be deleted")
        ok = await module.delete_entry(result["id"])
        assert ok is True
        fetched = await module.get_entry(result["id"])
        assert fetched is None

    async def test_delete_absent_entry_is_idempotent(self, module):
        ok = await module.delete_entry("2000-01-01-00-00-00")
        assert ok is True

    async def test_deleted_entry_absent_from_list(self, module):
        r1 = await module.create_entry("Keep")
        await asyncio.sleep(0.01)
        r2 = await module.create_entry("Delete me")
        await module.delete_entry(r2["id"])
        entries = await module.list_entries()
        assert len(entries) == 1
        assert entries[0]["id"] == r1["id"]


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

class TestSearchEntries:
    async def test_search_finds_matching_entry(self, module):
        await module.create_entry("The quick brown fox")
        await module.create_entry("Something completely different")
        results = await module.search_entries("quick fox")
        assert len(results) == 1
        assert "quick" in results[0]["content"]

    async def test_search_returns_match_count(self, module):
        await module.create_entry("apple apple apple")
        await module.create_entry("apple once")
        results = await module.search_entries("apple")
        # Higher match count first
        assert results[0]["match_count"] >= results[1]["match_count"]

    async def test_search_returns_snippet(self, module):
        await module.create_entry("Hello world this is a test entry for snippet extraction")
        results = await module.search_entries("snippet")
        assert len(results) == 1
        assert results[0]["snippet"] != ""

    async def test_search_empty_query_returns_empty(self, module):
        await module.create_entry("Some content")
        results = await module.search_entries("")
        assert results == []

    async def test_search_no_match_returns_empty(self, module):
        await module.create_entry("Hello world")
        results = await module.search_entries("zzzzz_no_match")
        assert results == []

