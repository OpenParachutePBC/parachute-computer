"""Tests for chat memory retrieval — shared handlers for MCP tools."""

import pytest
from unittest.mock import AsyncMock, MagicMock

from parachute.core.chat_memory import (
    search_chats,
    get_chat,
    get_exchange,
    _extract_snippet,
    _truncate,
    _determine_match_field,
)


def _make_graph(side_effects: list | None = None, return_value: list | None = None):
    """Create a mock BrainService with execute_cypher."""
    graph = MagicMock()
    if side_effects is not None:
        graph.execute_cypher = AsyncMock(side_effect=side_effects)
    elif return_value is not None:
        graph.execute_cypher = AsyncMock(return_value=return_value)
    else:
        graph.execute_cypher = AsyncMock(return_value=[])
    return graph


# ── Snippet & Truncation Helpers ─────────────────────────────────────────────


class TestExtractSnippet:
    def test_empty_content(self):
        assert _extract_snippet("", "query") == ""

    def test_match_at_beginning(self):
        content = "hello world, this is a test of snippet extraction"
        snippet = _extract_snippet(content, "hello", window=20)
        assert "hello" in snippet
        assert not snippet.startswith("...")

    def test_match_in_middle(self):
        content = "A" * 200 + "TARGET" + "B" * 200
        snippet = _extract_snippet(content, "TARGET", window=50)
        assert "TARGET" in snippet
        assert snippet.startswith("...")
        assert snippet.endswith("...")

    def test_no_match_returns_beginning(self):
        content = "abcdef" * 100
        snippet = _extract_snippet(content, "ZZZZZ", window=20)
        assert len(snippet) <= 25  # 20 + "..."
        assert snippet.endswith("...")

    def test_case_insensitive_match(self):
        content = "Hello World"
        snippet = _extract_snippet(content, "hello")
        assert "Hello" in snippet


class TestTruncate:
    def test_none_input(self):
        assert _truncate(None, 100) == ""

    def test_short_text(self):
        assert _truncate("hello", 100) == "hello"

    def test_exact_length(self):
        assert _truncate("hello", 5) == "hello"

    def test_over_limit(self):
        assert _truncate("hello world", 5) == "hello..."


class TestDetermineMatchField:
    def test_description_match(self):
        assert _determine_match_field("test", "other", "other", "test content") == "description"

    def test_user_message_match(self):
        assert _determine_match_field("test", "test content", "other", "other") == "user_message"

    def test_ai_response_match(self):
        assert _determine_match_field("test", "other", "test content", "other") == "ai_response"

    def test_description_preferred_over_user(self):
        assert _determine_match_field("test", "test a", "other", "test b") == "description"

    def test_case_insensitive(self):
        assert _determine_match_field("Test", "TEST content", "other", "other") == "user_message"


# ── search_chats ─────────────────────────────────────────────────────────────


class TestSearchChats:
    @pytest.mark.asyncio
    async def test_empty_query_returns_error(self):
        graph = _make_graph()
        result = await search_chats(graph, "")
        assert "error" in result
        assert "empty" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_title_match(self):
        """Chat found via title, no exchange matches."""
        title_rows = [
            {
                "session_id": "abc123",
                "title": "Building the MCP bridge",
                "summary": "Working on sandbox features",
                "module": "chat",
                "last_accessed": "2026-03-12T10:00:00",
                "created_at": "2026-03-12T09:00:00",
            }
        ]
        exchange_rows = []

        graph = _make_graph(side_effects=[title_rows, exchange_rows])
        result = await search_chats(graph, "MCP")

        assert result["count"] == 1
        chat = result["chats"][0]
        assert chat["session_id"] == "abc123"
        assert chat["match_source"] == "title"
        assert chat["matching_exchanges"] == []

    @pytest.mark.asyncio
    async def test_exchange_match(self):
        """Chat found via exchange content."""
        title_rows = []  # No title match
        exchange_rows = [
            {
                "session_id": "def456",
                "title": "Debug session",
                "summary": "Investigating a bug",
                "last_accessed": "2026-03-11T15:00:00",
                "module": "chat",
                "exchange_id": "def45678:ex:3",
                "exchange_number": "3",
                "description": "Discussed auth token handling",
                "user_message": "How should we handle auth tokens?",
                "ai_response": "I recommend bearer tokens with short expiry...",
            }
        ]

        graph = _make_graph(side_effects=[title_rows, exchange_rows])
        result = await search_chats(graph, "auth tokens")

        assert result["count"] == 1
        chat = result["chats"][0]
        assert chat["session_id"] == "def456"
        assert chat["match_source"] == "exchange"
        assert len(chat["matching_exchanges"]) == 1
        ex = chat["matching_exchanges"][0]
        assert ex["exchange_id"] == "def45678:ex:3"
        assert "auth token" in ex["user_snippet"].lower()

    @pytest.mark.asyncio
    async def test_dedup_title_and_exchange(self):
        """Same chat matched via title AND exchange — appears once with exchanges bundled."""
        title_rows = [
            {
                "session_id": "abc123",
                "title": "Token authentication",
                "summary": "Implementing token auth",
                "module": "chat",
                "last_accessed": "2026-03-12T10:00:00",
                "created_at": "2026-03-12T09:00:00",
            }
        ]
        exchange_rows = [
            {
                "session_id": "abc123",  # Same session!
                "title": "Token authentication",
                "summary": "Implementing token auth",
                "last_accessed": "2026-03-12T10:00:00",
                "module": "chat",
                "exchange_id": "abc12345:ex:1",
                "exchange_number": "1",
                "description": "Token validation flow",
                "user_message": "How does token validation work?",
                "ai_response": "The token is verified against the store...",
            }
        ]

        graph = _make_graph(side_effects=[title_rows, exchange_rows])
        result = await search_chats(graph, "token")

        # Should appear once, not twice
        assert result["count"] == 1
        chat = result["chats"][0]
        assert chat["session_id"] == "abc123"
        # Should have exchanges bundled
        assert len(chat["matching_exchanges"]) == 1
        # match_source stays as title (found via title first)
        assert chat["match_source"] == "title"

    @pytest.mark.asyncio
    async def test_no_results(self):
        graph = _make_graph(side_effects=[[], []])
        result = await search_chats(graph, "nonexistent query xyz")
        assert result["count"] == 0
        assert result["chats"] == []
        assert result["query"] == "nonexistent query xyz"

    @pytest.mark.asyncio
    async def test_module_filter(self):
        """Module parameter is passed to both queries."""
        graph = _make_graph(side_effects=[[], []])
        await search_chats(graph, "test", module="daily")

        # Both Cypher calls should include module filter
        assert graph.execute_cypher.call_count == 2
        for call in graph.execute_cypher.call_args_list:
            params = call[0][1]
            assert params.get("module") == "daily"

    @pytest.mark.asyncio
    async def test_limit_clamp(self):
        """Limit is clamped to 1-50."""
        graph = _make_graph(side_effects=[[], []])
        result = await search_chats(graph, "test", limit=0)
        # Should still work (clamped to 1)
        assert result["count"] == 0

    @pytest.mark.asyncio
    async def test_snippet_extraction_in_results(self):
        """Exchange snippets are extracted around the match."""
        title_rows = []
        long_user_msg = "A" * 200 + "FINDME" + "B" * 200
        exchange_rows = [
            {
                "session_id": "snap1",
                "title": "Snippet test",
                "summary": "",
                "last_accessed": "2026-03-12T10:00:00",
                "module": "chat",
                "exchange_id": "snap1234:ex:1",
                "exchange_number": "1",
                "description": "Some other description",
                "user_message": long_user_msg,
                "ai_response": "Shorter response",
            }
        ]

        graph = _make_graph(side_effects=[title_rows, exchange_rows])
        result = await search_chats(graph, "FINDME")

        ex = result["chats"][0]["matching_exchanges"][0]
        assert "FINDME" in ex["user_snippet"]
        assert ex["match_field"] == "user_message"
        # Snippet should be truncated, not the full 400+ char message
        assert len(ex["user_snippet"]) < len(long_user_msg)

    @pytest.mark.asyncio
    async def test_multiple_chats_sorted_by_recency(self):
        """Multiple chat results are sorted by last_accessed descending."""
        title_rows = [
            {
                "session_id": "old",
                "title": "test old",
                "summary": "",
                "module": "chat",
                "last_accessed": "2026-03-10T10:00:00",
                "created_at": "2026-03-10T09:00:00",
            },
            {
                "session_id": "new",
                "title": "test new",
                "summary": "",
                "module": "chat",
                "last_accessed": "2026-03-12T10:00:00",
                "created_at": "2026-03-12T09:00:00",
            },
        ]

        graph = _make_graph(side_effects=[title_rows, []])
        result = await search_chats(graph, "test")

        assert result["count"] == 2
        assert result["chats"][0]["session_id"] == "new"
        assert result["chats"][1]["session_id"] == "old"


# ── get_chat ─────────────────────────────────────────────────────────────────


class TestGetChat:
    @pytest.mark.asyncio
    async def test_empty_session_id(self):
        graph = _make_graph()
        result = await get_chat(graph, "")
        assert "error" in result

    @pytest.mark.asyncio
    async def test_not_found(self):
        graph = _make_graph(side_effects=[[]])
        result = await get_chat(graph, "nonexistent-id")
        assert "error" in result
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_with_exchanges(self):
        """Returns chat metadata + truncated exchanges in chronological order."""
        chat_row = [
            {
                "session_id": "abc123",
                "title": "Test Chat",
                "summary": "A test conversation",
                "module": "chat",
                "created_at": "2026-03-12T09:00:00",
                "last_accessed": "2026-03-12T10:00:00",
                "message_count": 10,
            }
        ]
        count_row = [{"total": 3}]
        exchange_rows = [
            {
                "exchange_id": "abc12345:ex:3",
                "exchange_number": "3",
                "description": "Third exchange",
                "user_message": "Third question",
                "ai_response": "Third answer",
                "tools_used": "",
                "created_at": "2026-03-12T10:00:00",
            },
            {
                "exchange_id": "abc12345:ex:2",
                "exchange_number": "2",
                "description": "Second exchange",
                "user_message": "Second question",
                "ai_response": "Second answer",
                "tools_used": "Read(file.txt)",
                "created_at": "2026-03-12T09:30:00",
            },
        ]

        graph = _make_graph(side_effects=[chat_row, count_row, exchange_rows])
        result = await get_chat(graph, "abc123")

        assert "chat" in result
        assert result["chat"]["session_id"] == "abc123"
        assert result["chat"]["title"] == "Test Chat"
        assert result["exchange_count"] == 3
        assert result["has_more"] is False  # 3 total, limit 25

        # Exchanges should be in chronological order (reversed from DESC)
        assert len(result["exchanges"]) == 2
        assert result["exchanges"][0]["exchange_number"] == "2"
        assert result["exchanges"][1]["exchange_number"] == "3"

    @pytest.mark.asyncio
    async def test_has_more_flag(self):
        """has_more is True when total exchanges > limit."""
        chat_row = [
            {
                "session_id": "abc123",
                "title": "Big Chat",
                "summary": "",
                "module": "chat",
                "created_at": "2026-03-12T09:00:00",
                "last_accessed": "2026-03-12T10:00:00",
                "message_count": 100,
            }
        ]
        count_row = [{"total": 50}]  # 50 exchanges total
        exchange_rows = [
            {
                "exchange_id": f"abc12345:ex:{i}",
                "exchange_number": str(i),
                "description": f"Exchange {i}",
                "user_message": f"Question {i}",
                "ai_response": f"Answer {i}",
                "tools_used": "",
                "created_at": f"2026-03-12T{10+i}:00:00",
            }
            for i in range(5, 0, -1)  # Only 5 returned (limit=5)
        ]

        graph = _make_graph(side_effects=[chat_row, count_row, exchange_rows])
        result = await get_chat(graph, "abc123", exchange_limit=5)

        assert result["exchange_count"] == 50
        assert result["has_more"] is True

    @pytest.mark.asyncio
    async def test_truncation(self):
        """Messages are truncated to max_chars."""
        long_message = "x" * 5000
        chat_row = [
            {
                "session_id": "abc123",
                "title": "Truncation test",
                "summary": "",
                "module": "chat",
                "created_at": "2026-03-12T09:00:00",
                "last_accessed": "2026-03-12T10:00:00",
                "message_count": 1,
            }
        ]
        count_row = [{"total": 1}]
        exchange_rows = [
            {
                "exchange_id": "abc12345:ex:1",
                "exchange_number": "1",
                "description": "Long message",
                "user_message": long_message,
                "ai_response": long_message,
                "tools_used": "",
                "created_at": "2026-03-12T09:00:00",
            }
        ]

        graph = _make_graph(side_effects=[chat_row, count_row, exchange_rows])
        result = await get_chat(graph, "abc123", max_chars=100)

        ex = result["exchanges"][0]
        assert len(ex["user_message"]) == 103  # 100 + "..."
        assert ex["user_message"].endswith("...")


# ── get_exchange ─────────────────────────────────────────────────────────────


class TestGetExchange:
    @pytest.mark.asyncio
    async def test_empty_id(self):
        graph = _make_graph()
        result = await get_exchange(graph, "")
        assert "error" in result

    @pytest.mark.asyncio
    async def test_not_found(self):
        graph = _make_graph(return_value=[])
        result = await get_exchange(graph, "nonexistent:ex:1")
        assert "error" in result
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_full_content(self):
        """Returns full untruncated content."""
        long_user = "U" * 10000
        long_ai = "A" * 10000
        exchange_row = [
            {
                "exchange_id": "abc12345:ex:5",
                "session_id": "abc123",
                "exchange_number": "5",
                "description": "A detailed exchange",
                "user_message": long_user,
                "ai_response": long_ai,
                "context": "Session was about testing",
                "tools_used": "Read(test.py), Bash(pytest)",
                "created_at": "2026-03-12T10:00:00",
            }
        ]

        graph = _make_graph(return_value=exchange_row)
        result = await get_exchange(graph, "abc12345:ex:5")

        assert "exchange" in result
        ex = result["exchange"]
        assert ex["exchange_id"] == "abc12345:ex:5"
        assert ex["session_id"] == "abc123"
        assert len(ex["user_message"]) == 10000  # Full, not truncated
        assert len(ex["ai_response"]) == 10000
        assert ex["tools_used"] == "Read(test.py), Bash(pytest)"
        assert ex["context"] == "Session was about testing"
