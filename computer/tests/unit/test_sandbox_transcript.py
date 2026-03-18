"""Tests for sandbox transcript loading from container JSONL and structured content blocks.

Covers:
- Loading messages from container bind-mounted JSONL (get_container_transcript_path)
- Fallback to host-side transcripts for legacy sessions
- _extract_message_blocks and _extract_message_content
- Backward compatibility with old plain-text transcripts
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


def _make_session(
    session_id: str = "test-session-001",
    wd: str | None = None,
    container_id: str | None = None,
) -> Session:
    return Session(
        id=session_id,
        module="chat",
        source=SessionSource.PARACHUTE,
        working_directory=wd,
        container_id=container_id,
        created_at=datetime.now(timezone.utc),
        last_accessed=datetime.now(timezone.utc),
    )


def _write_container_jsonl(
    parachute_dir: Path,
    container_id: str,
    session_id: str,
    events: list[dict],
    encoded_cwd: str = "-home-sandbox",
) -> Path:
    """Write JSONL events into a fake container bind-mount directory."""
    projects_dir = (
        parachute_dir / "sandbox" / "envs" / container_id / "home" / ".claude" / "projects" / encoded_cwd
    )
    projects_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = projects_dir / f"{session_id}.jsonl"
    with open(jsonl_path, "w") as f:
        for ev in events:
            f.write(json.dumps(ev) + "\n")
    return jsonl_path


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
# Container JSONL loading (replaces synthetic mirror round-trip tests)
# ──────────────────────────────────────────────────────────────────────

class TestContainerTranscriptPath:
    """get_container_transcript_path finds JSONL in bind-mounted home dirs."""

    def test_finds_transcript(self, session_manager, tmp_session_dir):
        """Finds JSONL in the container's .claude/projects/ directory."""
        _write_container_jsonl(
            tmp_session_dir, "abc123", "sess-001",
            [{"type": "user", "message": {"role": "user", "content": "hi"}}],
        )
        path = session_manager.get_container_transcript_path("abc123", "sess-001")
        assert path is not None
        assert path.exists()
        assert "abc123" in str(path)

    def test_returns_none_for_missing(self, session_manager):
        """Returns None when container env doesn't exist."""
        path = session_manager.get_container_transcript_path("nonexistent", "sess-001")
        assert path is None

    def test_finds_different_encoded_cwd(self, session_manager, tmp_session_dir):
        """Works regardless of encoded CWD name (e.g. -workspace vs -home-sandbox)."""
        _write_container_jsonl(
            tmp_session_dir, "abc123", "sess-002",
            [{"type": "user", "message": {"role": "user", "content": "hi"}}],
            encoded_cwd="-workspace",
        )
        path = session_manager.get_container_transcript_path("abc123", "sess-002")
        assert path is not None
        assert "-workspace" in str(path)


class TestContainerMessageLoading:
    """Messages load from container JSONL when container_id is set."""

    async def test_loads_from_container(self, session_manager, tmp_session_dir):
        """Sandboxed session loads messages from container bind-mount."""
        now = "2026-03-18T00:00:00Z"
        events = [
            {"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "text", "text": "Hi there!"}
            ]}, "timestamp": now},
            {"type": "result", "result": "Hi there!", "session_id": "sess-001", "timestamp": now},
        ]
        _write_container_jsonl(tmp_session_dir, "container-abc", "sess-001", events)

        session = _make_session(
            session_id="sess-001",
            wd=str(tmp_session_dir),
            container_id="container-abc",
        )
        messages = await session_manager._load_sdk_messages(session)

        assert len(messages) == 2  # user + assistant (result deduped)
        assert messages[0]["role"] == "user"
        assert messages[0]["content"] == "hello"
        assert messages[1]["role"] == "assistant"
        assert messages[1]["content"] == [{"type": "text", "text": "Hi there!"}]

    async def test_structured_content_from_container(self, session_manager, tmp_session_dir):
        """Thinking, tool_use, tool_result, and text blocks load correctly."""
        now = "2026-03-18T00:00:00Z"
        events = [
            {"type": "user", "message": {"role": "user", "content": "list files"}, "timestamp": now},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "thinking", "text": "Analyzing request..."},
                {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}},
                {"type": "tool_result", "toolUseId": "t1", "content": "file.txt", "isError": False},
                {"type": "text", "text": "Found file.txt"},
            ]}, "timestamp": now},
            {"type": "result", "result": "Found file.txt", "session_id": "sess-002", "timestamp": now},
        ]
        _write_container_jsonl(tmp_session_dir, "container-xyz", "sess-002", events)

        session = _make_session(session_id="sess-002", container_id="container-xyz")
        messages = await session_manager._load_sdk_messages(session)

        assistant = messages[1]
        content = assistant["content"]
        assert len(content) == 3  # thinking, tool_use(+result merged), text
        types = [b["type"] for b in content]
        assert types == ["thinking", "tool_use", "text"]
        assert content[1]["result"] == "file.txt"

    async def test_falls_back_to_host_when_no_container(self, session_manager, tmp_session_dir):
        """Sessions without container_id fall back to host-side transcript."""
        session = _make_session(wd=str(tmp_session_dir))
        transcript_path = session_manager.get_sdk_transcript_path(session.id, session.working_directory)
        transcript_path.parent.mkdir(parents=True, exist_ok=True)

        now = "2026-03-18T00:00:00Z"
        events = [
            {"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "text", "text": "Hi!"}
            ]}, "timestamp": now},
            {"type": "result", "result": "Hi!", "session_id": session.id, "timestamp": now},
        ]
        with open(transcript_path, "w") as f:
            for ev in events:
                f.write(json.dumps(ev) + "\n")

        messages = await session_manager._load_sdk_messages(session)
        assert len(messages) == 2
        assert messages[1]["content"] == [{"type": "text", "text": "Hi!"}]

    async def test_container_preferred_over_host(self, session_manager, tmp_session_dir):
        """When both container and host transcripts exist, container wins."""
        session_id = "sess-dual"
        container_id = "container-dual"

        # Write container transcript (newer, correct)
        now = "2026-03-18T00:00:00Z"
        _write_container_jsonl(tmp_session_dir, container_id, session_id, [
            {"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "text", "text": "Container response"}
            ]}, "timestamp": now},
        ])

        # Write host transcript (stale/incomplete)
        host_path = session_manager.get_sdk_transcript_path(session_id, str(tmp_session_dir))
        host_path.parent.mkdir(parents=True, exist_ok=True)
        with open(host_path, "w") as f:
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "hello"}, "timestamp": now}) + "\n")
            f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Host response (stale)"}]}, "timestamp": now}) + "\n")

        session = _make_session(session_id=session_id, wd=str(tmp_session_dir), container_id=container_id)
        messages = await session_manager._load_sdk_messages(session)

        assert messages[1]["content"] == [{"type": "text", "text": "Container response"}]


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
