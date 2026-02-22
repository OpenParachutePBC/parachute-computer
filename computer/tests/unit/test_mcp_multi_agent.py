"""
Tests for multi-agent MCP tools (create_session, send_message, list_workspace_sessions).

Tests session context injection, workspace isolation, trust level enforcement,
rate limiting, spawn limits, and content validation.
"""

import asyncio
import os
import tempfile
from datetime import datetime, timezone, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.db.database import Database, init_database
from parachute.models.session import Session, SessionCreate, SessionSource, TrustLevel
from parachute.mcp_server import (
    SessionContext,
    create_session,
    send_message,
    list_workspace_sessions,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def db():
    """Create a temporary test database."""
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = Path(f.name)

    try:
        database = await init_database(db_path)
        yield database
    finally:
        await database.close()
        if db_path.exists():
            db_path.unlink()


@pytest.fixture
def vault_path(tmp_path):
    """Create a temporary vault path."""
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / ".parachute").mkdir()
    return str(vault)


@pytest.fixture
async def parent_session(db: Database):
    """Create a parent session in the test database."""
    session_create = SessionCreate(
        id="parent_sess_abc123",
        title="Parent Session",
        module="chat",
        source=SessionSource.PARACHUTE,
        trust_level="direct",
        workspace_id="test-workspace",
    )
    session = await db.create_session(session_create)
    return session


@pytest.fixture
def session_context_direct():
    """Create a direct (trusted) session context."""
    return SessionContext(
        session_id="parent_sess_abc123",
        workspace_id="test-workspace",
        trust_level="direct",
    )


@pytest.fixture
def session_context_sandboxed():
    """Create a sandboxed (untrusted) session context."""
    return SessionContext(
        session_id="sandbox_sess_def456",
        workspace_id="test-workspace",
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
            workspace_id="my-workspace",
            trust_level="sandboxed",
        )
        assert ctx.session_id == "sess_123"
        assert ctx.workspace_id == "my-workspace"
        assert ctx.trust_level == "sandboxed"
        assert ctx.is_available

    def test_session_context_missing_vars(self):
        """Test SessionContext with missing fields."""
        ctx = SessionContext(
            session_id=None,
            workspace_id=None,
            trust_level=None,
        )
        assert ctx.session_id is None
        assert ctx.workspace_id is None
        assert ctx.trust_level is None
        assert not ctx.is_available

    def test_session_context_partial(self):
        """Test SessionContext with partial fields returns not available."""
        ctx = SessionContext(
            session_id="sess_123",
            workspace_id=None,
            trust_level="direct",
        )
        assert not ctx.is_available  # Not all required fields set


# ---------------------------------------------------------------------------
# create_session Tests
# ---------------------------------------------------------------------------


class TestCreateSession:
    @pytest.mark.asyncio
    async def test_create_session_success(self, db, parent_session, session_context_direct, vault_path):
        """Test successful child session creation."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server._vault_path", vault_path), \
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
            assert result["workspace_id"] == "test-workspace"
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
    async def test_create_session_spawn_limit(self, db, parent_session, session_context_direct, vault_path):
        """Test create_session enforces spawn limit (max 10 children)."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server._vault_path", vault_path), \
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
    async def test_create_session_rate_limiting(self, db, parent_session, session_context_direct, vault_path):
        """Test create_session enforces rate limiting (1/second)."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server._vault_path", vault_path), \
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


# ---------------------------------------------------------------------------
# send_message Tests
# ---------------------------------------------------------------------------


class TestSendMessage:
    @pytest.mark.asyncio
    async def test_send_message_success(self, db, parent_session, session_context_direct):
        """Test successful message sending."""
        # Create a recipient session in the same workspace
        recipient = SessionCreate(
            id="recipient_sess_789",
            title="Recipient",
            trust_level="direct",
            workspace_id="test-workspace",
        )
        await db.create_session(recipient)

        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await send_message(
                session_id="recipient_sess_789",
                message="Hello from parent!",
            )

            assert result["success"] is True
            assert result["sender_session_id"] == "parent_sess_abc123"
            assert result["recipient_session_id"] == "recipient_sess_789"

    @pytest.mark.asyncio
    async def test_send_message_no_context(self):
        """Test send_message fails without session context."""
        with patch("parachute.mcp_server._session_context", None):
            result = await send_message(
                session_id="recipient",
                message="Hello",
            )

            assert "error" in result
            assert "Session context not available" in result["error"]

    @pytest.mark.asyncio
    async def test_send_message_recipient_not_found(self, db, session_context_direct):
        """Test send_message fails if recipient doesn't exist."""
        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await send_message(
                session_id="nonexistent",
                message="Hello",
            )

            assert "error" in result
            assert "not found" in result["error"]

    @pytest.mark.asyncio
    async def test_send_message_workspace_boundary(self, db, parent_session, session_context_direct):
        """Test send_message enforces workspace boundaries."""
        # Create a recipient in a different workspace
        other_workspace_session = SessionCreate(
            id="other_sess_999",
            title="Other Workspace Session",
            trust_level="direct",
            workspace_id="other-workspace",
        )
        await db.create_session(other_workspace_session)

        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await send_message(
                session_id="other_sess_999",
                message="Cross-workspace message",
            )

            assert "error" in result
            assert "workspace boundaries" in result["error"]

    @pytest.mark.asyncio
    async def test_send_message_trust_level_enforcement(self, db, session_context_sandboxed):
        """Test sandboxed sessions can only message other sandboxed sessions."""
        # Create a sandboxed sender session
        sender = SessionCreate(
            id="sandbox_sess_def456",
            title="Sandboxed Sender",
            trust_level="sandboxed",
            workspace_id="test-workspace",
        )
        await db.create_session(sender)

        # Create a direct recipient in the same workspace
        recipient = SessionCreate(
            id="direct_sess_888",
            title="Direct Recipient",
            trust_level="direct",
            workspace_id="test-workspace",
        )
        await db.create_session(recipient)

        with patch("parachute.mcp_server._session_context", session_context_sandboxed), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await send_message(
                session_id="direct_sess_888",
                message="Trying to escalate",
            )

            assert "error" in result
            assert "Sandboxed sessions can only message other sandboxed sessions" in result["error"]

    @pytest.mark.asyncio
    async def test_send_message_content_validation(self, db, parent_session, session_context_direct):
        """Test send_message validates message content."""
        recipient = SessionCreate(
            id="recipient_sess_789",
            title="Recipient",
            trust_level="direct",
            workspace_id="test-workspace",
        )
        await db.create_session(recipient)

        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            # Test oversized message
            result = await send_message(
                session_id="recipient_sess_789",
                message="x" * 50_001,
            )
            assert "error" in result
            assert "too long" in result["error"]

            # Test control characters
            result = await send_message(
                session_id="recipient_sess_789",
                message="Hello\x00World",
            )
            assert "error" in result
            assert "control characters" in result["error"]


# ---------------------------------------------------------------------------
# list_workspace_sessions Tests
# ---------------------------------------------------------------------------


class TestListWorkspaceSessions:
    @pytest.mark.asyncio
    async def test_list_workspace_sessions_success(self, db, parent_session, session_context_direct):
        """Test successful listing of workspace sessions."""
        # Create a few more sessions in the same workspace
        for i in range(3):
            await db.create_session(SessionCreate(
                id=f"child_{i}",
                title=f"Child {i}",
                trust_level="direct",
                workspace_id="test-workspace",
            ))

        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await list_workspace_sessions()

            assert result["workspace_id"] == "test-workspace"
            assert result["caller_trust_level"] == "direct"
            assert result["total_sessions"] == 4  # parent + 3 children
            assert len(result["sessions"]) == 4

    @pytest.mark.asyncio
    async def test_list_workspace_sessions_no_context(self):
        """Test list_workspace_sessions fails without session context."""
        with patch("parachute.mcp_server._session_context", None):
            result = await list_workspace_sessions()

            assert "error" in result
            assert "Session context not available" in result["error"]

    @pytest.mark.asyncio
    async def test_list_workspace_sessions_trust_filtering(self, db, session_context_sandboxed):
        """Test sandboxed sessions only see other sandboxed sessions."""
        # Create sandboxed sender
        await db.create_session(SessionCreate(
            id="sandbox_sess_def456",
            title="Sandboxed Sender",
            trust_level="sandboxed",
            workspace_id="test-workspace",
        ))

        # Create mixed trust sessions in the same workspace
        await db.create_session(SessionCreate(
            id="direct_1",
            title="Direct 1",
            trust_level="direct",
            workspace_id="test-workspace",
        ))
        await db.create_session(SessionCreate(
            id="sandbox_1",
            title="Sandboxed 1",
            trust_level="sandboxed",
            workspace_id="test-workspace",
        ))
        await db.create_session(SessionCreate(
            id="sandbox_2",
            title="Sandboxed 2",
            trust_level="sandboxed",
            workspace_id="test-workspace",
        ))

        with patch("parachute.mcp_server._session_context", session_context_sandboxed), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await list_workspace_sessions()

            # Should only see 3 sandboxed sessions (sender + sandbox_1 + sandbox_2)
            assert result["total_sessions"] == 3
            for session in result["sessions"]:
                assert session["trust_level"] == "sandboxed"

    @pytest.mark.asyncio
    async def test_list_workspace_sessions_isolation(self, db, parent_session, session_context_direct):
        """Test workspace isolation - sessions from other workspaces not visible."""
        # Create sessions in another workspace
        for i in range(2):
            await db.create_session(SessionCreate(
                id=f"other_{i}",
                title=f"Other {i}",
                trust_level="direct",
                workspace_id="other-workspace",
            ))

        with patch("parachute.mcp_server._session_context", session_context_direct), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await list_workspace_sessions()

            # Should only see parent session (from test-workspace)
            assert result["total_sessions"] == 1
            assert result["sessions"][0]["id"] == "parent_sess_abc123"
