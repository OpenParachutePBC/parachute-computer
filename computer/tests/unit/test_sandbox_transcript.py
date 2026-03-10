"""Tests for sandbox transcript writing and loading (structured content blocks).

Covers the round-trip: write_sandbox_transcript → _load_sdk_messages,
ensuring thinking, tool_use, tool_result, and text blocks survive persistence.
Also tests backward compatibility with old plain-text transcripts.
"""

import json
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from parachute.core.session_manager import SessionManager
from parachute.models.session import Session, SessionSource


@pytest.fixture
def tmp_session_dir(tmp_path: Path) -> Path:
    """Create a fake .claude/projects directory for transcript storage."""
    projects_dir = tmp_path / ".claude" / "projects"
    projects_dir.mkdir(parents=True)
    return tmp_path


@pytest.fixture
def session_manager(tmp_session_dir: Path) -> SessionManager:
    """Session manager wired to a temp directory."""
    mgr = SessionManager(
        parachute_dir=tmp_session_dir,
        session_store=MagicMock(),
    )
    return mgr


def _make_session(session_id: str = "test-session-001", wd: str | None = None) -> Session:
    return Session(
        id=session_id,
        module="chat",
        source=SessionSource.PARACHUTE,
        working_directory=wd,
        created_at=datetime.now(timezone.utc),
        last_accessed=datetime.now(timezone.utc),
    )


# ──────────────────────────────────────────────────────────────────────
# _extract_message_blocks
# ──────────────────────────────────────────────────────────────────────

class TestExtractMessageBlocks:
    """Unit tests for _extract_message_blocks()."""

    def test_string_content(self, session_manager: SessionManager):
        msg = {"content": "hello world"}
        blocks = session_manager._extract_message_blocks(msg)
        assert blocks == [{"type": "text", "text": "hello world"}]

    def test_empty_string(self, session_manager: SessionManager):
        msg = {"content": ""}
        blocks = session_manager._extract_message_blocks(msg)
        assert blocks == []

    def test_list_with_text(self, session_manager: SessionManager):
        msg = {"content": [{"type": "text", "text": "hi"}]}
        blocks = session_manager._extract_message_blocks(msg)
        assert blocks == [{"type": "text", "text": "hi"}]

    def test_list_with_thinking(self, session_manager: SessionManager):
        msg = {"content": [{"type": "thinking", "text": "pondering..."}]}
        blocks = session_manager._extract_message_blocks(msg)
        assert blocks == [{"type": "thinking", "text": "pondering..."}]

    def test_list_with_tool_use(self, session_manager: SessionManager):
        msg = {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 1
        assert blocks[0]["type"] == "tool_use"
        assert blocks[0]["name"] == "Bash"

    def test_tool_result_merged_into_tool_use(self, session_manager: SessionManager):
        """tool_result blocks are merged into matching tool_use blocks."""
        msg = {"content": [
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
            {"type": "tool_result", "toolUseId": "t1", "content": "file.txt", "isError": False},
        ]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 1  # tool_result is folded, not separate
        assert blocks[0]["type"] == "tool_use"
        assert blocks[0]["result"] == "file.txt"
        assert blocks[0]["isError"] is False

    def test_tool_result_list_content_normalized(self, session_manager: SessionManager):
        """tool_result with list content (multi-part) is joined to string."""
        msg = {"content": [
            {"type": "tool_use", "id": "t1", "name": "Read", "input": {}},
            {"type": "tool_result", "toolUseId": "t1", "content": [
                {"type": "text", "text": "line 1"},
                {"type": "text", "text": "line 2"},
            ], "isError": False},
        ]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 1
        assert blocks[0]["result"] == "line 1\nline 2"

    def test_orphaned_tool_result_dropped(self, session_manager: SessionManager):
        """tool_result with no matching tool_use is silently dropped."""
        msg = {"content": [
            {"type": "tool_result", "toolUseId": "no-match", "content": "orphan", "isError": False},
            {"type": "text", "text": "hello"},
        ]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 1
        assert blocks[0]["type"] == "text"

    def test_mixed_blocks_with_merge(self, session_manager: SessionManager):
        msg = {"content": [
            {"type": "thinking", "text": "hmm"},
            {"type": "tool_use", "id": "t1", "name": "Read", "input": {}},
            {"type": "tool_result", "toolUseId": "t1", "content": "file data", "isError": False},
            {"type": "text", "text": "done"},
        ]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 3  # thinking, tool_use(+result), text
        types = [b["type"] for b in blocks]
        assert types == ["thinking", "tool_use", "text"]
        assert blocks[1]["result"] == "file data"

    def test_bare_strings_in_list(self, session_manager: SessionManager):
        msg = {"content": ["hello", "world"]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 2
        assert all(b["type"] == "text" for b in blocks)

    def test_unknown_block_type_ignored(self, session_manager: SessionManager):
        msg = {"content": [{"type": "image", "url": "http://..."}]}
        blocks = session_manager._extract_message_blocks(msg)
        assert blocks == []

    def test_no_content_key(self, session_manager: SessionManager):
        blocks = session_manager._extract_message_blocks({})
        assert blocks == []


class TestExtractMessageContentBackcompat:
    """_extract_message_content still works for text-only consumers."""

    def test_returns_text_from_blocks(self, session_manager: SessionManager):
        msg = {"content": [
            {"type": "thinking", "text": "ignored"},
            {"type": "text", "text": "hello"},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}},
            {"type": "text", "text": "world"},
        ]}
        result = session_manager._extract_message_content(msg)
        assert result == "hello\nworld"

    def test_returns_none_for_tool_only(self, session_manager: SessionManager):
        msg = {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}
        result = session_manager._extract_message_content(msg)
        assert result is None


# ──────────────────────────────────────────────────────────────────────
# Round-trip: write_sandbox_transcript → _load_sdk_messages
# ──────────────────────────────────────────────────────────────────────

class TestSandboxTranscriptRoundTrip:
    """Structured content survives write → load."""

    async def _write_and_load(self, session_manager, session, user_msg, content_blocks):
        """Helper: write transcript then load messages."""
        session_manager.write_sandbox_transcript(
            session.id,
            user_msg,
            content_blocks,
            working_directory=session.working_directory,
        )
        return await session_manager._load_sdk_messages(session)

    async def test_text_only(self, session_manager, tmp_session_dir):
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [{"type": "text", "text": "Hello!"}]
        messages = await self._write_and_load(session_manager, session, "hi", blocks)

        assert len(messages) == 2  # user + assistant (result deduped)
        assert messages[0]["role"] == "user"
        assert messages[0]["content"] == "hi"
        assert messages[1]["role"] == "assistant"
        assert messages[1]["content"] == [{"type": "text", "text": "Hello!"}]

    async def test_thinking_and_text(self, session_manager, tmp_session_dir):
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [
            {"type": "thinking", "text": "Let me think..."},
            {"type": "text", "text": "Here's my answer"},
        ]
        messages = await self._write_and_load(session_manager, session, "question?", blocks)

        assistant = messages[1]
        assert assistant["role"] == "assistant"
        content = assistant["content"]
        assert len(content) == 2
        assert content[0]["type"] == "thinking"
        assert content[0]["text"] == "Let me think..."
        assert content[1]["type"] == "text"

    async def test_full_structured_content(self, session_manager, tmp_session_dir):
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [
            {"type": "thinking", "text": "Analyzing request..."},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
            {"type": "tool_result", "toolUseId": "t1", "content": "file.txt", "isError": False},
            {"type": "text", "text": "Found file.txt"},
        ]
        messages = await self._write_and_load(session_manager, session, "list files", blocks)

        assistant = messages[1]
        content = assistant["content"]
        # tool_result merged into tool_use → 3 blocks, not 4
        assert len(content) == 3
        types = [b["type"] for b in content]
        assert types == ["thinking", "tool_use", "text"]
        assert content[1]["name"] == "Bash"
        assert content[1]["result"] == "file.txt"
        assert content[1]["isError"] is False

    async def test_multi_turn(self, session_manager, tmp_session_dir):
        """Multiple write calls append correctly."""
        session = _make_session(wd=str(tmp_session_dir))

        # Turn 1
        session_manager.write_sandbox_transcript(
            session.id, "hello",
            [{"type": "text", "text": "Hi there!"}],
            working_directory=session.working_directory,
        )
        # Turn 2
        session_manager.write_sandbox_transcript(
            session.id, "how are you?",
            [{"type": "thinking", "text": "reflecting..."}, {"type": "text", "text": "I'm good!"}],
            working_directory=session.working_directory,
        )

        messages = await session_manager._load_sdk_messages(session)
        assert len(messages) == 4  # user1, asst1, user2, asst2
        # Second assistant message has thinking block
        assert messages[3]["content"][0]["type"] == "thinking"

    async def test_tool_result_list_content_round_trip(self, session_manager, tmp_session_dir):
        """tool_result with list content survives write → load → merge."""
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [
            {"type": "tool_use", "id": "t1", "name": "Read", "input": {"path": "/tmp/f"}},
            {"type": "tool_result", "toolUseId": "t1", "content": [
                {"type": "text", "text": "first line"},
                {"type": "text", "text": "second line"},
            ], "isError": False},
            {"type": "text", "text": "Done reading"},
        ]
        messages = await self._write_and_load(session_manager, session, "read it", blocks)

        assistant = messages[1]
        content = assistant["content"]
        assert len(content) == 2  # tool_use(+result), text
        assert content[0]["type"] == "tool_use"
        assert content[0]["result"] == "first line\nsecond line"


# ──────────────────────────────────────────────────────────────────────
# Backward compatibility with old plain-text transcripts
# ──────────────────────────────────────────────────────────────────────

class TestBackwardCompatibility:
    """Old transcripts with plain text content still load."""

    async def test_old_format_loads(self, session_manager, tmp_session_dir):
        """Transcripts from before this fix (text-only) still work."""
        session = _make_session(wd=str(tmp_session_dir))
        transcript_path = session_manager.get_sdk_transcript_path(session.id, session.working_directory)
        transcript_path.parent.mkdir(parents=True, exist_ok=True)

        # Write old-format transcript (plain text content blocks)
        now = "2026-03-10T00:00:00Z"
        old_events = [
            {"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Hi!"}]}, "timestamp": now},
            {"type": "result", "result": "Hi!", "session_id": session.id, "timestamp": now},
        ]
        with open(transcript_path, "w") as f:
            for ev in old_events:
                f.write(json.dumps(ev) + "\n")

        messages = await session_manager._load_sdk_messages(session)

        assert len(messages) == 2  # user + assistant (result deduped)
        assert messages[1]["content"] == [{"type": "text", "text": "Hi!"}]

    async def test_result_only_no_assistant(self, session_manager, tmp_session_dir):
        """Very old format: only result event, no assistant event."""
        session = _make_session(wd=str(tmp_session_dir))
        transcript_path = session_manager.get_sdk_transcript_path(session.id, session.working_directory)
        transcript_path.parent.mkdir(parents=True, exist_ok=True)

        now = "2026-03-10T00:00:00Z"
        old_events = [
            {"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now},
            {"type": "result", "result": "Hi!", "session_id": session.id, "timestamp": now},
        ]
        with open(transcript_path, "w") as f:
            for ev in old_events:
                f.write(json.dumps(ev) + "\n")

        messages = await session_manager._load_sdk_messages(session)

        assert len(messages) == 2
        assert messages[1]["content"] == [{"type": "text", "text": "Hi!"}]

    async def test_string_content_message(self, session_manager, tmp_session_dir):
        """Old format where assistant content is a bare string."""
        session = _make_session(wd=str(tmp_session_dir))
        transcript_path = session_manager.get_sdk_transcript_path(session.id, session.working_directory)
        transcript_path.parent.mkdir(parents=True, exist_ok=True)

        now = "2026-03-10T00:00:00Z"
        old_events = [
            {"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now},
            {"type": "assistant", "message": {"role": "assistant", "content": "Hi there!"}, "timestamp": now},
            {"type": "result", "result": "Hi there!", "session_id": session.id, "timestamp": now},
        ]
        with open(transcript_path, "w") as f:
            for ev in old_events:
                f.write(json.dumps(ev) + "\n")

        messages = await session_manager._load_sdk_messages(session)

        assert len(messages) == 2  # result deduped
        assert messages[1]["content"] == [{"type": "text", "text": "Hi there!"}]
