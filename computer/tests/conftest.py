"""
Pytest configuration and fixtures.
"""

import os
import tempfile
from pathlib import Path
from typing import AsyncGenerator

import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from httpx import AsyncClient

# Set test environment
os.environ["LOG_LEVEL"] = "WARNING"


# ---------------------------------------------------------------------------
# LadybugDB platform compatibility check
# ---------------------------------------------------------------------------
# The real_ladybug native layer has a known "ANY type" bug on some Linux
# builds. Detect it once at import time and expose a flag for fixtures.

def _check_ladybugdb_compat() -> bool:
    """Return True if LadybugDB parameterized writes work on this platform."""
    import asyncio
    from parachute.db.brain import BrainService
    from parachute.db.brain_chat_store import BrainChatStore
    from parachute.models.session import SessionCreate

    async def _probe():
        with tempfile.TemporaryDirectory() as d:
            svc = BrainService(Path(d) / "probe.kz")
            await svc.connect()
            store = BrainChatStore(svc)
            await store.ensure_schema()
            # Test 1: simple session create
            await store.create_session(
                SessionCreate(id="__probe__", title="probe", module="test")
            )
            # Test 2: complex parameterized MERGE (exact shape from daily module)
            # This catches the "ANY type" bug on Linux with many params
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
                    "title": "probe",
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
        return True

    try:
        return asyncio.run(_probe())
    except RuntimeError as e:
        if "ANY type" in str(e):
            return False
        raise


LADYBUGDB_WORKS = _check_ladybugdb_compat()

requires_ladybugdb = pytest.mark.skipif(
    not LADYBUGDB_WORKS,
    reason="LadybugDB native layer has ANY type bug on this platform",
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def test_vault(tmp_path: Path) -> Path:
    """Create a fresh test vault for each test."""
    vault = tmp_path / "test-vault"
    vault.mkdir()

    # Create minimal vault structure
    (vault / "Chat").mkdir()
    (vault / "Chat" / "sessions").mkdir()
    (vault / "Chat" / "contexts").mkdir()
    (vault / "Chat" / "assets").mkdir()

    (vault / "Daily").mkdir()
    (vault / "Daily" / "journals").mkdir()

    (vault / ".parachute").mkdir()
    (vault / "agents").mkdir()

    # Create a general context file
    (vault / "Chat" / "contexts" / "general-context.md").write_text(
        """# Test Context

This is a test vault for automated testing.

## User Info
- Name: Test User
- Purpose: Testing
"""
    )

    return vault


@pytest.fixture
def test_home_path(test_vault: Path) -> str:
    """Get test vault path as string."""
    return str(test_vault)


@pytest_asyncio.fixture
async def test_database(tmp_path: Path):
    """Create a test graph chat store. Skips if LadybugDB is broken."""
    if not LADYBUGDB_WORKS:
        pytest.skip("LadybugDB native layer has ANY type bug on this platform")

    from parachute.db.brain import BrainService
    from parachute.db.brain_chat_store import BrainChatStore

    db_path = tmp_path / "test-graph" / "parachute.kz"
    graph = BrainService(db_path=db_path)
    await graph.connect()
    store = BrainChatStore(graph)
    await store.ensure_schema()

    yield store


@pytest_asyncio.fixture
async def session_manager(tmp_path: Path, test_database):
    """Create a session manager for testing."""
    from parachute.core.session_manager import SessionManager

    parachute_dir = tmp_path / ".parachute"
    parachute_dir.mkdir(exist_ok=True)
    return SessionManager(parachute_dir, test_database)


@pytest.fixture
def test_settings(tmp_path: Path):
    """Create test settings."""
    from parachute.config import Settings

    return Settings(
        port=3334,  # Different port for testing
        host="127.0.0.1",
        log_level="WARNING",
    )


@pytest.fixture
def test_client(test_settings) -> TestClient:
    """Create a FastAPI test client."""
    from parachute.server import app

    with TestClient(app) as client:
        yield client


@pytest_asyncio.fixture
async def async_client(test_settings) -> AsyncGenerator[AsyncClient, None]:
    """Create an async HTTP client for testing."""
    from parachute.server import app

    async with AsyncClient(app=app, base_url="http://test") as client:
        yield client


@pytest.fixture
def sample_agent_md() -> str:
    """Sample agent definition markdown."""
    return """---
agent:
  name: Test Agent
  description: A test agent for automated testing
  type: chatbot
  tools:
    - Read
    - Write
    - Glob
  permissions:
    read: ["*"]
    write: ["Documents/*"]
---

# Test Agent

You are a test agent for automated testing.
Be helpful and concise.
"""


@pytest.fixture
def sample_session_data() -> dict:
    """Sample session data for testing."""
    return {
        "id": "test-session-12345678-1234-1234-1234-123456789abc",
        "title": "Test Session",
        "module": "chat",
        "source": "parachute",
        "message_count": 0,
    }
