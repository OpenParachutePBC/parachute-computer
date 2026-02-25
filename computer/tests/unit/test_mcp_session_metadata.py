"""
Tests for MCP session metadata tools (update_session_title, update_session_summary).

Verifies that the tools correctly update the current session's title and summary
via the MCP server's own DB connection, including the title_source guard.
"""

import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest
import pytest_asyncio

from parachute.db.database import Database, init_database
from parachute.models.session import SessionCreate, SessionSource
from parachute.mcp_server import (
    SessionContext,
    _handle_update_session_title,
    _handle_update_session_summary,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
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


@pytest_asyncio.fixture
async def session(db: Database):
    """Create a test session in the database."""
    session_create = SessionCreate(
        id="sess_abc1234567890abc",
        title=None,
        module="chat",
        source=SessionSource.PARACHUTE,
        trust_level="sandboxed",
        workspace_id="test-workspace",
    )
    return await db.create_session(session_create)


@pytest.fixture
def ctx():
    """Direct session context pointing at the test session."""
    return SessionContext(
        session_id="sess_abc1234567890abc",
        workspace_id="test-workspace",
        trust_level="sandboxed",
    )


# ---------------------------------------------------------------------------
# update_session_title tests
# ---------------------------------------------------------------------------


class TestUpdateSessionTitle:
    @pytest.mark.asyncio
    async def test_sets_title_and_ai_source(self, db, session, ctx):
        """update_session_title writes the title and sets title_source=ai."""
        with patch("parachute.mcp_server._session_context", ctx), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await _handle_update_session_title("My New Title")

        assert result["status"] == "ok"
        assert result["title"] == "My New Title"

        updated = await db.get_session(session.id)
        assert updated.title == "My New Title"
        assert updated.metadata["title_source"] == "ai"

    @pytest.mark.asyncio
    async def test_respects_user_title_source(self, db, session, ctx):
        """update_session_title refuses to overwrite a user-set title."""
        from parachute.models.session import SessionUpdate

        # Simulate user renaming the session
        await db.update_session(
            session.id, SessionUpdate(title="User Title", metadata={"title_source": "user"})
        )

        with patch("parachute.mcp_server._session_context", ctx), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await _handle_update_session_title("AI Override Attempt")

        assert result["status"] == "protected"
        # Title must be unchanged
        unchanged = await db.get_session(session.id)
        assert unchanged.title == "User Title"

    @pytest.mark.asyncio
    async def test_overwrites_existing_ai_title(self, db, session, ctx):
        """update_session_title can overwrite a previous AI-set title."""
        from parachute.models.session import SessionUpdate

        await db.update_session(
            session.id, SessionUpdate(title="Old AI Title", metadata={"title_source": "ai"})
        )

        with patch("parachute.mcp_server._session_context", ctx), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await _handle_update_session_title("New AI Title")

        assert result["status"] == "ok"
        updated = await db.get_session(session.id)
        assert updated.title == "New AI Title"

    @pytest.mark.asyncio
    async def test_no_session_context(self, db):
        """Returns error when no session context is available."""
        with patch("parachute.mcp_server._session_context", None):
            result = await _handle_update_session_title("Should Fail")

        assert "error" in result
        assert "No session context" in result["error"]

    @pytest.mark.asyncio
    async def test_session_not_found(self, db, ctx):
        """Returns error when session_id doesn't exist in the DB."""
        missing_ctx = SessionContext(
            session_id="sess_doesnotexist1234",
            workspace_id="test-workspace",
            trust_level="direct",
        )
        with patch("parachute.mcp_server._session_context", missing_ctx), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await _handle_update_session_title("Title")

        assert "error" in result
        assert "not found" in result["error"]


# ---------------------------------------------------------------------------
# update_session_summary tests
# ---------------------------------------------------------------------------


class TestUpdateSessionSummary:
    @pytest.mark.asyncio
    async def test_sets_summary(self, db, session, ctx):
        """update_session_summary writes the summary to the session record."""
        with patch("parachute.mcp_server._session_context", ctx), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await _handle_update_session_summary(
                "Discussed MCP tools and session metadata."
            )

        assert result["status"] == "ok"
        updated = await db.get_session(session.id)
        assert updated.summary == "Discussed MCP tools and session metadata."

    @pytest.mark.asyncio
    async def test_overwrites_previous_summary(self, db, session, ctx):
        """update_session_summary replaces any existing summary."""
        from parachute.models.session import SessionUpdate

        await db.update_session(session.id, SessionUpdate(summary="Old summary."))

        with patch("parachute.mcp_server._session_context", ctx), \
             patch("parachute.mcp_server.get_db", return_value=db):

            result = await _handle_update_session_summary("New summary.")

        assert result["status"] == "ok"
        updated = await db.get_session(session.id)
        assert updated.summary == "New summary."

    @pytest.mark.asyncio
    async def test_no_session_context(self, db):
        """Returns error when no session context is available."""
        with patch("parachute.mcp_server._session_context", None):
            result = await _handle_update_session_summary("Should Fail")

        assert "error" in result
        assert "No session context" in result["error"]
