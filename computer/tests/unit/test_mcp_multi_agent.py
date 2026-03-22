"""
Tests for multi-agent MCP tools (create_session).

Tests session context injection, trust level enforcement, rate limiting,
spawn limits, and content validation.

Note: send_message was removed (not yet implemented, tracked in #303).
"""

import asyncio
import os
from datetime import datetime, timezone, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.db.brain_chat_store import BrainChatStore
from parachute.models.session import Session, SessionCreate, SessionSource, TrustLevel
from parachute.mcp_server import (
    SessionContext,
    create_session,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def db(tmp_path):
    """Create a temporary test graph session store."""
    from parachute.db.brain import BrainService

    graph = BrainService(db_path=tmp_path / "test.kz")
    await graph.connect()
    store = BrainChatStore(graph)
    await store.ensure_schema()
    yield store


@pytest.fixture
def vault_path(tmp_path):
    """Create a temporary vault path."""
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / ".parachute").mkdir()
    return str(vault)


@pytest.fixture
async def parent_session(db: BrainChatStore):
    """Create a parent session in the test database."""
    session_create = SessionCreate(
        id="parent_sess_abc123",
        title="Parent Session",
        module="chat",
        source=SessionSource.PARACHUTE,
        trust_level="direct",
    )
    session = await db.create_session(session_create)
    return session


@pytest.fixture
def session_context_direct():
    """Create a direct (trusted) session context."""
    return SessionContext(
        session_id="parent_sess_abc123",
        trust_level="direct",
    )


@pytest.fixture
def session_context_sandboxed():
    """Create a sandboxed (untrusted) session context."""
    return SessionContext(
        session_id="sandbox_sess_def456",
        trust_level="sandboxed",
    )


# ---------------------------------------------------------------------------
# SessionContext Tests
# ---------------------------------------------------------------------------


class TestSessionContext:
    def test_session_context_all_set(self):
        """Test SessionContext with all fields set."""
        ctx = SessionContext(
            session_id="sess_123",
            trust_level="sandboxed",
        )
        assert ctx.session_id == "sess_123"
        assert ctx.trust_level == "sandboxed"
        assert ctx.is_available

    def test_session_context_missing_vars(self):
        """Test SessionContext with missing fields."""
        ctx = SessionContext(
            session_id=None,
            trust_level=None,
        )
        assert ctx.session_id is None
        assert ctx.trust_level is None
        assert not ctx.is_available

    def test_session_context_partial(self):
        """Test SessionContext with partial fields returns not available."""
        ctx = SessionContext(
            session_id="sess_123",
            trust_level=None,
        )
        assert not ctx.is_available  # Not all required fields set


# ---------------------------------------------------------------------------
# create_session Tests
# ---------------------------------------------------------------------------


class TestCreateSession:
    @pytest.mark.asyncio
    async def test_create_session_success(self, db, parent_session, session_context_direct):
        """Test successful child session creation."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await create_session(
                title="Child Session",
                agent_type="researcher",
                initial_message="Hello, world!",
            )

            assert result["success"] is True
            assert "session_id" in result
            assert result["title"] == "Child Session"
            assert result["agent_type"] == "researcher"
            assert result["trust_level"] == "direct"
            assert result["parent_session_id"] == "parent_sess_abc123"

            # Verify session was created in database
            session = await db.get_session(result["session_id"])
            assert session is not None
            assert session.parent_session_id == "parent_sess_abc123"
            assert session.created_by == "agent:parent_sess_abc123"

    @pytest.mark.asyncio
    async def test_create_session_no_context(self, db):
        """Test create_session fails without session context."""
        with patch("parachute.mcp_server._session_context", None):
            result = await create_session(
                title="Child Session",
                agent_type="researcher",
                initial_message="Hello",
            )

            assert "error" in result
            assert "Session context not available" in result["error"]

    @pytest.mark.asyncio
    async def test_create_session_empty_title(self, db, parent_session, session_context_direct):
        """Test create_session rejects empty title."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await create_session(
                title="  ",
                agent_type="researcher",
                initial_message="Hello",
            )

            assert "error" in result
            assert "Title cannot be empty" in result["error"]

    @pytest.mark.asyncio
    async def test_create_session_invalid_agent_type(self, db, parent_session, session_context_direct):
        """Test create_session rejects invalid agent_type characters."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await create_session(
                title="Test",
                agent_type="invalid/type",  # Contains slash
                initial_message="Hello",
            )

            assert "error" in result
            assert "Invalid agent_type" in result["error"]

    @pytest.mark.asyncio
    async def test_create_session_message_too_long(self, db, parent_session, session_context_direct):
        """Test create_session rejects oversized message."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await create_session(
                title="Test",
                agent_type="researcher",
                initial_message="x" * 50_001,  # Exceeds 50k limit
            )

            assert "error" in result
            assert "too long" in result["error"]

    @pytest.mark.asyncio
    async def test_create_session_control_chars_rejected(self, db, parent_session, session_context_direct):
        """Test create_session rejects control characters in message."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await create_session(
                title="Test",
                agent_type="researcher",
                initial_message="Hello\x00World",  # NULL byte
            )

            assert "error" in result
            assert "control characters" in result["error"]

    @pytest.mark.asyncio
    async def test_create_session_spawn_limit(self, db, parent_session, session_context_direct):
        """Test create_session enforces spawn limit (max 10 children)."""
        # Mock get_last_child_created to return an old timestamp so rate limiter doesn't trigger
        old_timestamp = datetime.now(timezone.utc) - timedelta(seconds=5)
        db.get_last_child_created = AsyncMock(return_value=old_timestamp)

        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            # Create 10 child sessions
            for i in range(10):
                result = await create_session(
                    title=f"Child {i}",
                    agent_type="worker",
                    initial_message="Work",
                )
                assert result["success"] is True

            # 11th should fail
            result = await create_session(
                title="Child 11",
                agent_type="worker",
                initial_message="Work",
            )

            assert "error" in result
            assert "Spawn limit reached" in result["error"]

    @pytest.mark.asyncio
    async def test_create_session_rate_limiting(self, db, parent_session, session_context_direct):
        """Test create_session enforces rate limiting (1/second)."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            # First session succeeds
            result1 = await create_session(
                title="Child 1",
                agent_type="worker",
                initial_message="Work",
            )
            assert result1["success"] is True

            # Second session immediately after should fail
            result2 = await create_session(
                title="Child 2",
                agent_type="worker",
                initial_message="Work",
            )

            assert "error" in result2
            assert "Rate limit" in result2["error"]



# send_message tests removed — tool disabled pending implementation (#303)


