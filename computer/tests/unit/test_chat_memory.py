"""Tests for vault tools — shared handlers for MCP tools."""

import pytest
from unittest.mock import AsyncMock, MagicMock

from parachute.core.vault_tools import (
    search_chats,
    get_chat,
    get_exchange,
    write_note,
    _extract_snippet,
    _truncate,
    _determine_match_field,
)


def _make_graph(
    side_effects: list | None = None,
    return_value: list | None = None,
) -> MagicMock:
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
        assert _determine_match_field("test", "other", "test content") == "description"

    def test_content_match(self):
        assert _determine_match_field("test", "test content", "other") == "content"

    def test_description_preferred_over_content(self):
        assert _determine_match_field("test", "test a", "test b") == "description"

    def test_case_insensitive(self):
        assert _determine_match_field("Test", "TEST content", "other") == "content"

    def test_no_match(self):
        assert _determine_match_field("test", "other", "other") == "unknown"


# ── search_chats ─────────────────────────────────────────────────────────────


class TestSearchChats:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("bad_query", ["", "   ", "\t"])
    async def test_empty_or_whitespace_query_returns_error(self, bad_query):
        graph = _make_graph()
        result = await search_chats(graph, bad_query)
        assert "error" in result
        assert "empty" in result["error"].lower()

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
    async def test_message_match(self):
        """Chat found via message content."""
        title_rows = []  # No title match
        message_rows = [
            {
                "session_id": "def456",
                "title": "Debug session",
                "summary": "Investigating a bug",
                "last_accessed": "2026-03-11T15:00:00",
                "module": "chat",
                "message_id": "def45678:msg:3",
                "sequence": 3,
                "role": "human",
                "description": "Discussed auth token handling",
                "content": "How should we handle auth tokens?",
            }
        ]

        graph = _make_graph(side_effects=[title_rows, message_rows])
        result = await search_chats(graph, "auth tokens")

        assert result["count"] == 1
        chat = result["chats"][0]
        assert chat["session_id"] == "def456"
        assert chat["match_source"] == "message"
        assert len(chat["matching_exchanges"]) == 1
        ex = chat["matching_exchanges"][0]
        assert ex["exchange_id"] == "def45678:msg:3"
        assert "auth token" in ex["user_snippet"].lower()

    @pytest.mark.asyncio
    async def test_dedup_title_and_message(self):
        """Same chat matched via title AND message — appears once with messages bundled."""
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
        message_rows = [
            {
                "session_id": "abc123",  # Same session!
                "title": "Token authentication",
                "summary": "Implementing token auth",
                "last_accessed": "2026-03-12T10:00:00",
                "module": "chat",
                "message_id": "abc12345:msg:1",
                "sequence": 1,
                "role": "human",
                "description": "Token validation flow",
                "content": "How does token validation work?",
            }
        ]

        graph = _make_graph(side_effects=[title_rows, message_rows])
        result = await search_chats(graph, "token")

        # Should appear once, not twice
        assert result["count"] == 1
        chat = result["chats"][0]
        assert chat["session_id"] == "abc123"
        # Should have messages bundled
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
        """Message snippets are extracted around the match."""
        title_rows = []
        long_content = "A" * 200 + "FINDME" + "B" * 200
        message_rows = [
            {
                "session_id": "snap1",
                "title": "Snippet test",
                "summary": "",
                "last_accessed": "2026-03-12T10:00:00",
                "module": "chat",
                "message_id": "snap1234:msg:1",
                "sequence": 1,
                "role": "human",
                "description": "Some other description",
                "content": long_content,
            }
        ]

        graph = _make_graph(side_effects=[title_rows, message_rows])
        result = await search_chats(graph, "FINDME")

        ex = result["chats"][0]["matching_exchanges"][0]
        assert "FINDME" in ex["user_snippet"]
        assert ex["match_field"] == "content"
        # Snippet should be truncated, not the full 400+ char message
        assert len(ex["user_snippet"]) < len(long_content)

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
    async def test_with_messages(self):
        """Returns chat metadata + messages paired as exchanges in chronological order."""
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
        count_row = [{"total": 4}]  # 4 messages = 2 exchanges
        # DESC order from query, then reversed in code
        message_rows = [
            {
                "message_id": "abc12345:msg:4",
                "sequence": 4,
                "role": "machine",
                "content": "Second answer",
                "description": "Second exchange desc",
                "tools_used": "Read(file.txt)",
                "status": "complete",
                "created_at": "2026-03-12T10:00:00",
            },
            {
                "message_id": "abc12345:msg:3",
                "sequence": 3,
                "role": "human",
                "content": "Second question",
                "description": "",
                "tools_used": "",
                "status": "complete",
                "created_at": "2026-03-12T09:30:00",
            },
            {
                "message_id": "abc12345:msg:2",
                "sequence": 2,
                "role": "machine",
                "content": "First answer",
                "description": "First exchange desc",
                "tools_used": "",
                "status": "complete",
                "created_at": "2026-03-12T09:01:00",
            },
            {
                "message_id": "abc12345:msg:1",
                "sequence": 1,
                "role": "human",
                "content": "First question",
                "description": "",
                "tools_used": "",
                "status": "complete",
                "created_at": "2026-03-12T09:00:00",
            },
        ]

        graph = _make_graph(side_effects=[chat_row, count_row, message_rows])
        result = await get_chat(graph, "abc123")

        assert "chat" in result
        assert result["chat"]["session_id"] == "abc123"
        assert result["chat"]["title"] == "Test Chat"

        # Should pair messages into exchanges
        assert len(result["exchanges"]) == 2
        assert result["exchanges"][0]["user_message"] == "First question"
        assert result["exchanges"][0]["ai_response"] == "First answer"
        assert result["exchanges"][1]["user_message"] == "Second question"
        assert result["exchanges"][1]["ai_response"] == "Second answer"

    @pytest.mark.asyncio
    async def test_has_more_flag(self):
        """has_more is True when total messages > limit."""
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
        count_row = [{"total": 100}]  # 100 messages total
        message_rows = [
            {
                "message_id": f"abc12345:msg:{i}",
                "sequence": i,
                "role": "human" if i % 2 == 1 else "machine",
                "content": f"Content {i}",
                "description": f"Message {i}",
                "tools_used": "",
                "status": "complete",
                "created_at": f"2026-03-12T{10}:00:0{i}",
            }
            for i in range(10, 0, -1)  # Only 10 returned (limit=5 → 10 messages)
        ]

        graph = _make_graph(side_effects=[chat_row, count_row, message_rows])
        result = await get_chat(graph, "abc123", exchange_limit=5)

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
                "message_count": 2,
            }
        ]
        count_row = [{"total": 2}]
        message_rows = [
            {
                "message_id": "abc12345:msg:2",
                "sequence": 2,
                "role": "machine",
                "content": long_message,
                "description": "Long message",
                "tools_used": "",
                "status": "complete",
                "created_at": "2026-03-12T09:01:00",
            },
            {
                "message_id": "abc12345:msg:1",
                "sequence": 1,
                "role": "human",
                "content": long_message,
                "description": "",
                "tools_used": "",
                "status": "complete",
                "created_at": "2026-03-12T09:00:00",
            },
        ]

        graph = _make_graph(side_effects=[chat_row, count_row, message_rows])
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
        result = await get_exchange(graph, "nonexistent:msg:1")
        assert "error" in result
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_full_content(self):
        """Returns full untruncated content via exchange-compat shape."""
        long_content = "U" * 10000
        message_row = [
            {
                "message_id": "abc12345:msg:1",
                "session_id": "abc123",
                "sequence": 1,
                "role": "human",
                "content": long_content,
                "description": "A detailed message",
                "context": "Session was about testing",
                "tools_used": "",
                "thinking": "",
                "status": "complete",
                "created_at": "2026-03-12T10:00:00",
            }
        ]

        graph = _make_graph(return_value=message_row)
        result = await get_exchange(graph, "abc12345:msg:1")

        assert "exchange" in result
        ex = result["exchange"]
        assert ex["exchange_id"] == "abc12345:msg:1"
        assert ex["session_id"] == "abc123"
        assert len(ex["user_message"]) == 10000  # Full, not truncated
        assert ex["context"] == "Session was about testing"


# ── write_note ──────────────────────────────────────────────────────────────


class TestWriteNote:
    @pytest.mark.asyncio
    async def test_empty_note_type(self):
        graph = _make_graph()
        result = await write_note(graph, "", "Title", "Content")
        assert "error" in result
        assert "note_type" in result["error"]

    @pytest.mark.asyncio
    async def test_empty_title(self):
        graph = _make_graph()
        result = await write_note(graph, "context", "", "Content")
        assert "error" in result
        assert "title" in result["error"]

    @pytest.mark.asyncio
    async def test_empty_content(self):
        graph = _make_graph()
        result = await write_note(graph, "context", "Profile", "")
        assert "error" in result
        assert "content" in result["error"]

    @pytest.mark.asyncio
    async def test_content_too_large(self):
        graph = _make_graph()
        result = await write_note(graph, "context", "Profile", "x" * 10_001)
        assert "error" in result
        assert "too large" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_invalid_date_format(self):
        graph = _make_graph()
        result = await write_note(graph, "journal", "Entry", "Content", date="not-a-date")
        assert "error" in result
        assert "date" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_context_note_creates_with_deterministic_id(self):
        graph = _make_graph()
        result = await write_note(graph, "context", "Profile", "Name: Aaron")

        assert result["status"] == "updated"
        assert result["entry_id"] == "context:profile"
        assert result["note_type"] == "context"
        assert result["title"] == "Profile"

        # Should use MERGE with the deterministic entry_id (first call)
        # Second call conditionally sets created_at on new nodes
        assert graph.execute_cypher.call_count == 2
        first_call = graph.execute_cypher.call_args_list[0]
        cypher = first_call[0][0]
        assert "MERGE" in cypher
        params = first_call[0][1]
        assert params["entry_id"] == "context:profile"

    @pytest.mark.asyncio
    async def test_context_note_title_normalization(self):
        """Context entry_id is normalized from the title."""
        graph = _make_graph()
        result = await write_note(graph, "context", "Current Focus", "Parachute thesis")
        assert result["entry_id"] == "context:current-focus"

    @pytest.mark.asyncio
    async def test_non_context_note_creates_with_generated_id(self):
        graph = _make_graph()
        result = await write_note(graph, "reference", "API Notes", "Some API docs")

        assert result["status"] == "created"
        assert result["note_type"] == "reference"
        assert result["title"] == "API Notes"
        # entry_id should be a timestamp format, not context:*
        assert not result["entry_id"].startswith("context:")
        assert "date" in result

    @pytest.mark.asyncio
    async def test_journal_note_with_date(self):
        graph = _make_graph()
        result = await write_note(graph, "journal", "Morning", "Felt good today", date="2026-03-22")

        assert result["status"] == "created"
        assert result["date"] == "2026-03-22"

    @pytest.mark.asyncio
    async def test_note_type_normalized_to_lowercase(self):
        graph = _make_graph()
        result = await write_note(graph, "  Context  ", "Profile", "Content")
        assert result["note_type"] == "context"
        assert result["entry_id"] == "context:profile"
