"""
Pytest configuration and fixtures.
"""

import asyncio
import os
from pathlib import Path
from typing import AsyncGenerator, Generator

import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from httpx import AsyncClient

# Set test environment
os.environ["LOG_LEVEL"] = "WARNING"


@pytest.fixture(scope="session")
def event_loop() -> Generator[asyncio.AbstractEventLoop, None, None]:
    """Create an event loop for the test session."""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


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
    """Create a test graph chat store."""
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


@pytest.fixture
def minimal_bot_connector():
    """Minimal BotConnector subclass for unit testing base functionality.

    Returns a BotConnector class (not instance) that can be instantiated
    with test-specific configuration.

    Usage:
        def test_something(minimal_bot_connector):
            connector = minimal_bot_connector(
                bot_token="test",
                server=None,
                allowed_users=[123, 456],
            )
            assert connector.is_user_allowed(123)
    """
    from parachute.connectors.base import BotConnector

    class TestConnector(BotConnector):
        platform = "test"

        async def start(self):
            pass

        async def stop(self):
            pass

        async def on_text_message(self, update, context):
            pass

        async def _run_loop(self):
            pass

    return TestConnector
