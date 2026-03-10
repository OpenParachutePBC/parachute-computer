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

    def test_list_with_tool_result(self, session_manager: SessionManager):
        msg = {"content": [{"type": "tool_result", "toolUseId": "t1", "content": "output", "isError": False}]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 1
        assert blocks[0]["type"] == "tool_result"

    def test_mixed_blocks(self, session_manager: SessionManager):
        msg = {"content": [
            {"type": "thinking", "text": "hmm"},
            {"type": "tool_use", "id": "t1", "name": "Read", "input": {}},
            {"type": "tool_result", "toolUseId": "t1", "content": "file data", "isError": False},
            {"type": "text", "text": "done"},
        ]}
        blocks = session_manager._extract_message_blocks(msg)
        assert len(blocks) == 4
        types = [b["type"] for b in blocks]
        assert types == ["thinking", "tool_use", "tool_result", "text"]

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

    def _write_and_load(self, session_manager, session, user_msg, content_blocks):
        """Helper: write transcript then load messages."""
        session_manager.write_sandbox_transcript(
            session.id,
            user_msg,
            content_blocks,
            working_directory=session.working_directory,
        )
        import asyncio
        return asyncio.get_event_loop().run_until_complete(
            session_manager._load_sdk_messages(session)
        )

    def test_text_only(self, session_manager, tmp_session_dir):
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [{"type": "text", "text": "Hello!"}]
        messages = self._write_and_load(session_manager, session, "hi", blocks)

        assert len(messages) == 2  # user + assistant (result deduped)
        assert messages[0]["role"] == "user"
        assert messages[0]["content"] == "hi"
        assert messages[1]["role"] == "assistant"
        assert messages[1]["content"] == [{"type": "text", "text": "Hello!"}]

    def test_thinking_and_text(self, session_manager, tmp_session_dir):
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [
            {"type": "thinking", "text": "Let me think..."},
            {"type": "text", "text": "Here's my answer"},
        ]
        messages = self._write_and_load(session_manager, session, "question?", blocks)

        assistant = messages[1]
        assert assistant["role"] == "assistant"
        content = assistant["content"]
        assert len(content) == 2
        assert content[0]["type"] == "thinking"
        assert content[0]["text"] == "Let me think..."
        assert content[1]["type"] == "text"

    def test_full_structured_content(self, session_manager, tmp_session_dir):
        session = _make_session(wd=str(tmp_session_dir))
        blocks = [
            {"type": "thinking", "text": "Analyzing request..."},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
            {"type": "tool_result", "toolUseId": "t1", "content": "file.txt", "isError": False},
            {"type": "text", "text": "Found file.txt"},
        ]
        messages = self._write_and_load(session_manager, session, "list files", blocks)

        assistant = messages[1]
        content = assistant["content"]
        assert len(content) == 4
        types = [b["type"] for b in content]
        assert types == ["thinking", "tool_use", "tool_result", "text"]
        assert content[1]["name"] == "Bash"
        assert content[2]["content"] == "file.txt"

    def test_multi_turn(self, session_manager, tmp_session_dir):
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

        import asyncio
        messages = asyncio.get_event_loop().run_until_complete(
            session_manager._load_sdk_messages(session)
        )
        assert len(messages) == 4  # user1, asst1, user2, asst2
        # Second assistant message has thinking block
        assert messages[3]["content"][0]["type"] == "thinking"


# ──────────────────────────────────────────────────────────────────────
# Backward compatibility with old plain-text transcripts
# ──────────────────────────────────────────────────────────────────────

class TestBackwardCompatibility:
    """Old transcripts with plain text content still load."""

    def test_old_format_loads(self, session_manager, tmp_session_dir):
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

        import asyncio
        messages = asyncio.get_event_loop().run_until_complete(
            session_manager._load_sdk_messages(session)
        )

        assert len(messages) == 2  # user + assistant (result deduped)
        assert messages[1]["content"] == [{"type": "text", "text": "Hi!"}]

    def test_result_only_no_assistant(self, session_manager, tmp_session_dir):
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

        import asyncio
        messages = asyncio.get_event_loop().run_until_complete(
            session_manager._load_sdk_messages(session)
        )

        assert len(messages) == 2
        assert messages[1]["content"] == [{"type": "text", "text": "Hi!"}]

    def test_string_content_message(self, session_manager, tmp_session_dir):
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

        import asyncio
        messages = asyncio.get_event_loop().run_until_complete(
            session_manager._load_sdk_messages(session)
        )

        assert len(messages) == 2  # result deduped
        assert messages[1]["content"] == [{"type": "text", "text": "Hi there!"}]
