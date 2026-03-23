"""
Tests for multi-agent MCP tools (create_session).

Tests session context injection, trust level enforcement, rate limiting,
spawn limits, and content validation.

Now tests the HTTP endpoint at POST /api/chat/children since the MCP
server routes through HTTP loopback (no direct DB access).

Note: send_message was removed (not yet implemented, tracked in #303).
"""

import uuid
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock

import pytest
from httpx import AsyncClient, ASGITransport

from parachute.db.brain_chat_store import BrainChatStore
from parachute.models.session import SessionCreate, SessionSource
from parachute.mcp_server import SessionContext


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
async def app(db):
    """Create a test FastAPI app with the sessions router."""
    from fastapi import FastAPI
    from parachute.api.sessions import router

    app = FastAPI()
    app.include_router(router, prefix="/api")
    app.state.session_store = db
    app.state.orchestrator = None
    return app


@pytest.fixture
async def client(app):
    """Create an async test client."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


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
# create_child_session Endpoint Tests
# ---------------------------------------------------------------------------


class TestCreateChildSessionEndpoint:
    @pytest.mark.asyncio
    async def test_create_session_success(self, client, db, parent_session):
        """Test successful child session creation via HTTP endpoint."""
        response = await client.post("/api/chat/children", json={
            "title": "Child Session",
            "agentType": "researcher",
            "initialMessage": "Hello, world!",
            "parentSessionId": "parent_sess_abc123",
            "trustLevel": "direct",
        })

        assert response.status_code == 200
        result = response.json()
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
    async def test_create_session_invalid_agent_type(self, client, parent_session):
        """Test endpoint rejects invalid agent_type characters."""
        response = await client.post("/api/chat/children", json={
            "title": "Test",
            "agentType": "invalid/type",
            "initialMessage": "Hello",
            "parentSessionId": "parent_sess_abc123",
        })

        assert response.status_code == 400
        assert "Invalid agent_type" in response.json()["detail"]

    @pytest.mark.asyncio
    async def test_create_session_message_too_long(self, client, parent_session):
        """Test endpoint rejects oversized message."""
        response = await client.post("/api/chat/children", json={
            "title": "Test",
            "agentType": "researcher",
            "initialMessage": "x" * 50_001,
            "parentSessionId": "parent_sess_abc123",
        })

        assert response.status_code == 400
        assert "too long" in response.json()["detail"]

    @pytest.mark.asyncio
    async def test_create_session_spawn_limit(self, client, db, parent_session):
        """Test endpoint enforces spawn limit (max 10 children)."""
        # Mock get_last_child_created to avoid rate limiting
        old_timestamp = datetime.now(timezone.utc) - timedelta(seconds=5)
        db.get_last_child_created = AsyncMock(return_value=old_timestamp)

        # Create 10 child sessions
        for i in range(10):
            response = await client.post("/api/chat/children", json={
                "title": f"Child {i}",
                "agentType": "worker",
                "initialMessage": "Work",
                "parentSessionId": "parent_sess_abc123",
            })
            assert response.status_code == 200

        # 11th should fail
        response = await client.post("/api/chat/children", json={
            "title": "Child 11",
            "agentType": "worker",
            "initialMessage": "Work",
            "parentSessionId": "parent_sess_abc123",
        })

        assert response.status_code == 429
        assert "Spawn limit" in response.json()["detail"]

    @pytest.mark.asyncio
    async def test_create_session_rate_limiting(self, client, db, parent_session):
        """Test endpoint enforces rate limiting (1/second)."""
        # First session succeeds
        response1 = await client.post("/api/chat/children", json={
            "title": "Child 1",
            "agentType": "worker",
            "initialMessage": "Work",
            "parentSessionId": "parent_sess_abc123",
        })
        assert response1.status_code == 200

        # Second session immediately after should fail
        response2 = await client.post("/api/chat/children", json={
            "title": "Child 2",
            "agentType": "worker",
            "initialMessage": "Work",
            "parentSessionId": "parent_sess_abc123",
        })

        assert response2.status_code == 429
        assert "Rate limit" in response2.json()["detail"]


# send_message tests removed — tool disabled pending implementation (#303)
