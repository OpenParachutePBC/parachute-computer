"""
Unit tests for daily agent tools (read_days_chats, summarize_chat, read_recent_cards).

Tests graph-backed tool functions with a real temporary Kuzu database.
The summarize_chat sub-agent call is mocked (no real SDK invocation).
"""

import asyncio
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio

from parachute.db.brain import BrainService
from parachute.db.brain_chat_store import BrainChatStore

from tests.conftest import LADYBUGDB_WORKS

pytestmark = pytest.mark.skipif(
    not LADYBUGDB_WORKS,
    reason="LadybugDB native layer has ANY type bug on this platform",
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture
async def graph(tmp_path):
    """Live temporary Kuzu database with full schema."""
    db_path = tmp_path / "graph.db"
    svc = BrainService(db_path)
    await svc.connect()
    store = BrainChatStore(svc)
    await store.ensure_schema()

    yield svc

    if svc._conn:
        conn = svc._conn
        if hasattr(conn, "executor") and conn.executor:
            conn.executor.shutdown(wait=False, cancel_futures=True)
    svc._connected = False
    svc._conn = None
    svc._db = None


@pytest_asyncio.fixture
async def graph_with_chat_data(graph):
    """Graph pre-loaded with a chat session and messages for 2026-03-25."""
    # Create a chat session
    await graph.execute_cypher(
        "CREATE (s:Chat {session_id: $sid, title: $title, module: $module, "
        "  summary: $summary, last_accessed: $la, created_at: $ca, "
        "  message_count: 4, archived: false})",
        {
            "sid": "test-session-1",
            "title": "Working on daily agent",
            "module": "chat",
            "summary": "",
            "la": "2026-03-25T22:00:00+00:00",
            "ca": "2026-03-24T10:00:00+00:00",
        },
    )

    # Create messages — 2 from yesterday (context), 2 from today
    messages = [
        ("msg-1", "human", "Let's work on the daily agent", "2026-03-24T10:00:00+00:00", 1),
        ("msg-2", "machine", "Sure, I'll start with the tools.", "2026-03-24T10:05:00+00:00", 2),
        ("msg-3", "human", "Now let's rewrite read_days_chats", "2026-03-25T14:00:00+00:00", 3),
        ("msg-4", "machine", "Done, it now queries the graph.", "2026-03-25T14:30:00+00:00", 4),
    ]
    for mid, role, content, created_at, seq in messages:
        await graph.execute_cypher(
            "CREATE (m:Message {message_id: $mid, session_id: $sid, role: $role, "
            "  content: $content, created_at: $ca, sequence: $seq, "
            "  status: 'complete', updated_at: $ca})",
            {"mid": mid, "sid": "test-session-1", "role": role, "content": content, "ca": created_at, "seq": seq},
        )
        await graph.execute_cypher(
            "MATCH (s:Chat {session_id: $sid}), (m:Message {message_id: $mid}) "
            "CREATE (s)-[:HAS_MESSAGE]->(m)",
            {"sid": "test-session-1", "mid": mid},
        )

    # Create a second session with NO messages on 2026-03-25
    await graph.execute_cypher(
        "CREATE (s:Chat {session_id: $sid, title: $title, module: $module, "
        "  summary: '', last_accessed: $la, created_at: $ca, "
        "  message_count: 1, archived: false})",
        {
            "sid": "test-session-old",
            "title": "Old session",
            "module": "chat",
            "la": "2026-03-20T10:00:00+00:00",
            "ca": "2026-03-20T10:00:00+00:00",
        },
    )

    return graph


@pytest_asyncio.fixture
async def graph_with_cards(graph):
    """Graph pre-loaded with cards for testing read_recent_cards."""
    cards = [
        ("process-day:reflection:2026-03-24", "process-day", "reflection", "Daily Reflection", "2026-03-24", "Reflection for March 24."),
        ("process-day:reflection:2026-03-23", "process-day", "reflection", "Daily Reflection", "2026-03-23", "Reflection for March 23."),
        ("process-day:default:2026-03-22", "process-day", "default", "Daily Reflection", "2026-03-22", "Default card."),
    ]
    for card_id, agent, ctype, display, date, content in cards:
        await graph.execute_cypher(
            "CREATE (c:Card {card_id: $cid, agent_name: $agent, card_type: $ctype, "
            "  display_name: $display, date: $date, content: $content, "
            "  generated_at: $ga, status: 'done', read_at: ''})",
            {"cid": card_id, "agent": agent, "ctype": ctype, "display": display, "date": date, "content": content, "ga": f"{date}T04:00:00+00:00"},
        )

    return graph


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_tool(factory_name: str, graph, scope=None, agent_name="test-agent", home_path=None):
    """Create a tool handler from its factory. Returns the async handler function."""
    from parachute.core.daily_agent_tools import (
        _make_read_days_chats,
        _make_read_recent_cards,
        _make_summarize_chat,
    )
    factories = {
        "read_days_chats": _make_read_days_chats,
        "summarize_chat": _make_summarize_chat,
        "read_recent_cards": _make_read_recent_cards,
    }
    factory = factories[factory_name]
    sdk_tool = factory(graph, scope or {}, agent_name, home_path or Path("/tmp"))
    return sdk_tool.handler  # Return the async handler, not the SdkMcpTool wrapper


# ---------------------------------------------------------------------------
# Tests: read_days_chats
# ---------------------------------------------------------------------------

class TestReadDaysChats:
    @pytest.mark.asyncio
    async def test_returns_sessions_for_date(self, graph_with_chat_data):
        tool = _make_tool("read_days_chats", graph_with_chat_data, scope={"date": "2026-03-25"})
        result = await tool({"date": "2026-03-25"})
        text = result["content"][0]["text"]

        assert "Working on daily agent" in text
        assert "test-session-1" in text
        assert "Messages today:** 2" in text
        # Old session should NOT appear (no messages on 2026-03-25)
        assert "Old session" not in text

    @pytest.mark.asyncio
    async def test_no_sessions_found(self, graph_with_chat_data):
        tool = _make_tool("read_days_chats", graph_with_chat_data, scope={"date": "2026-01-01"})
        result = await tool({"date": "2026-01-01"})
        text = result["content"][0]["text"]
        assert "No chat sessions found" in text

    @pytest.mark.asyncio
    async def test_missing_date(self, graph):
        tool = _make_tool("read_days_chats", graph, scope={"date": ""})
        result = await tool({"date": ""})
        assert result.get("is_error") is True

    @pytest.mark.asyncio
    async def test_graph_unavailable(self):
        tool = _make_tool("read_days_chats", None, scope={"date": "2026-03-25"})
        result = await tool({"date": "2026-03-25"})
        assert "graph unavailable" in result["content"][0]["text"]


# ---------------------------------------------------------------------------
# Tests: summarize_chat
# ---------------------------------------------------------------------------

class TestSummarizeChat:
    @pytest.mark.asyncio
    async def test_summarizes_session(self, graph_with_chat_data):
        """Test that summarize_chat reads messages and calls sub-agent."""
        tool = _make_tool("summarize_chat", graph_with_chat_data, scope={"date": "2026-03-25"})

        mock_response = (
            "SESSION SUMMARY:\n"
            "This conversation is about building daily agent tools.\n\n"
            "TODAY'S ACTIVITY:\n"
            "Rewrote read_days_chats to query the graph instead of filesystem."
        )

        with patch(
            "parachute.core.daily_agent_tools._call_summarizer_subagent",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_sub:
            result = await tool({"session_id": "test-session-1"})
            text = result["content"][0]["text"]
            assert "Rewrote read_days_chats" in text

            # Verify sub-agent was called with transcript containing [TODAY] markers
            call_args = mock_sub.call_args
            transcript = call_args[0][1]
            assert "[TODAY]" in transcript

        # Verify summary was persisted to the graph
        rows = await graph_with_chat_data.execute_cypher(
            "MATCH (s:Chat {session_id: 'test-session-1'}) "
            "RETURN s.summary AS summary, s.summary_updated_at AS updated_at"
        )
        assert rows[0]["summary"] == "This conversation is about building daily agent tools."
        assert rows[0]["updated_at"] != ""

    @pytest.mark.asyncio
    async def test_skips_session_with_no_today_messages(self, graph_with_chat_data):
        """Session with messages only on other dates returns early."""
        # test-session-1 has messages on 2026-03-24 and 2026-03-25.
        # Ask for a date where it has messages but not on this specific date.
        tool = _make_tool("summarize_chat", graph_with_chat_data, scope={"date": "2026-03-20"})
        result = await tool({"session_id": "test-session-1"})
        text = result["content"][0]["text"]
        assert "No messages on 2026-03-20" in text

    @pytest.mark.asyncio
    async def test_skips_session_with_no_messages_at_all(self, graph_with_chat_data):
        """Session with zero messages returns early."""
        tool = _make_tool("summarize_chat", graph_with_chat_data, scope={"date": "2026-03-25"})
        result = await tool({"session_id": "test-session-old"})
        text = result["content"][0]["text"]
        assert "No messages found" in text

    @pytest.mark.asyncio
    async def test_uses_cached_summary(self, graph_with_chat_data):
        """If summary is fresh (updated after latest message), skip re-summarization."""
        # Latest message in fixture is at 2026-03-25T14:30:00+00:00 (msg-4).
        # Set summary_updated_at after that to trigger cache hit.
        await graph_with_chat_data.execute_cypher(
            "MATCH (s:Chat {session_id: 'test-session-1'}) "
            "SET s.summary = 'Cached summary', "
            "    s.summary_updated_at = '2026-03-25T23:00:00+00:00'"
        )

        tool = _make_tool("summarize_chat", graph_with_chat_data, scope={"date": "2026-03-25"})
        result = await tool({"session_id": "test-session-1"})
        text = result["content"][0]["text"]
        assert "(cached)" in text
        assert "Cached summary" in text

    @pytest.mark.asyncio
    async def test_missing_session_id(self, graph):
        tool = _make_tool("summarize_chat", graph, scope={"date": "2026-03-25"})
        result = await tool({"session_id": ""})
        assert result.get("is_error") is True


# ---------------------------------------------------------------------------
# Tests: read_recent_cards
# ---------------------------------------------------------------------------

class TestReadRecentCards:
    """Tests for read_recent_cards. Pins datetime.now to 2026-03-25 so
    fixture dates (2026-03-22 through 2026-03-24) are always within range."""

    FROZEN_NOW = datetime(2026, 3, 25, 12, 0, 0, tzinfo=timezone.utc)

    @pytest.mark.asyncio
    async def test_reads_all_cards(self, graph_with_cards):
        tool = _make_tool("read_recent_cards", graph_with_cards)
        with patch("parachute.core.daily_agent_tools.datetime") as mock_dt:
            mock_dt.now.return_value = self.FROZEN_NOW
            mock_dt.side_effect = lambda *a, **kw: datetime(*a, **kw)
            result = await tool({"days": 7})
        text = result["content"][0]["text"]
        assert "3 found" in text
        assert "Reflection for March 24" in text
        assert "Default card" in text

    @pytest.mark.asyncio
    async def test_filters_by_card_type(self, graph_with_cards):
        tool = _make_tool("read_recent_cards", graph_with_cards)
        with patch("parachute.core.daily_agent_tools.datetime") as mock_dt:
            mock_dt.now.return_value = self.FROZEN_NOW
            mock_dt.side_effect = lambda *a, **kw: datetime(*a, **kw)
            result = await tool({"days": 7, "card_type": "reflection"})
        text = result["content"][0]["text"]
        assert "2 found" in text
        assert "Reflection for March 24" in text
        assert "Default card" not in text

    @pytest.mark.asyncio
    async def test_no_cards_found(self, graph_with_cards):
        tool = _make_tool("read_recent_cards", graph_with_cards)
        with patch("parachute.core.daily_agent_tools.datetime") as mock_dt:
            mock_dt.now.return_value = self.FROZEN_NOW
            mock_dt.side_effect = lambda *a, **kw: datetime(*a, **kw)
            result = await tool({"days": 1, "card_type": "nonexistent"})
        text = result["content"][0]["text"]
        assert "No cards" in text

    @pytest.mark.asyncio
    async def test_graph_unavailable(self):
        tool = _make_tool("read_recent_cards", None)
        result = await tool({"days": 7})
        assert "Graph unavailable" in result["content"][0]["text"]


# ---------------------------------------------------------------------------
# Tests: _parse_summarizer_response
# ---------------------------------------------------------------------------

class TestParseSummarizerResponse:
    def test_parses_structured_response(self):
        from parachute.core.daily_agent_tools import _parse_summarizer_response

        response = (
            "SESSION SUMMARY:\nThis is about X.\n\n"
            "TODAY'S ACTIVITY:\nWe did Y and Z."
        )
        summary, activity = _parse_summarizer_response(response)
        assert "This is about X" in summary
        assert "We did Y and Z" in activity

    def test_fallback_on_unstructured_response(self):
        from parachute.core.daily_agent_tools import _parse_summarizer_response

        response = "Just a plain summary of everything."
        summary, activity = _parse_summarizer_response(response)
        assert summary == response
        assert activity == response
