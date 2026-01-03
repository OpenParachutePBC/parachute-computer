"""
Pytest configuration and fixtures.
"""

import asyncio
import os
import tempfile
from pathlib import Path
from typing import AsyncGenerator, Generator

import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from httpx import AsyncClient

# Set test environment
os.environ["VAULT_PATH"] = tempfile.mkdtemp(prefix="parachute-test-")
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
def test_vault_path(test_vault: Path) -> str:
    """Get test vault path as string."""
    return str(test_vault)


@pytest_asyncio.fixture
async def test_database(test_vault: Path):
    """Create a test database."""
    from parachute.db.database import Database

    db_path = test_vault / ".parachute" / "sessions.db"
    db = Database(db_path)
    await db.connect()

    yield db

    await db.close()


@pytest_asyncio.fixture
async def session_manager(test_vault: Path, test_database):
    """Create a session manager for testing."""
    from parachute.core.session_manager import SessionManager

    return SessionManager(test_vault, test_database)


@pytest.fixture
def test_settings(test_vault: Path):
    """Create test settings."""
    from parachute.config import Settings

    return Settings(
        vault_path=test_vault,
        port=3334,  # Different port for testing
        host="127.0.0.1",
        log_level="WARNING",
    )


@pytest.fixture
def test_client(test_settings) -> TestClient:
    """Create a FastAPI test client."""
    # Import app after setting environment
    os.environ["VAULT_PATH"] = str(test_settings.vault_path)

    from parachute.server import app

    with TestClient(app) as client:
        yield client


@pytest_asyncio.fixture
async def async_client(test_settings) -> AsyncGenerator[AsyncClient, None]:
    """Create an async HTTP client for testing."""
    os.environ["VAULT_PATH"] = str(test_settings.vault_path)

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
